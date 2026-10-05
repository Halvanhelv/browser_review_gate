require "test_helper"

module BrowserReviewGate
  class UnitsTest < Minitest::Test
    include TestData

    def test_an_assessment_answer_that_is_malformed_is_invalid
      [ "not json", answer(decision: "maybe"), answer(reason: "  "), answer(covered_by_report: "yes"), '["required"]' ].each do |text|
        refute Assessment.parse(text, assessed_sha: HEAD).valid?, text
      end
      refute Assessment.parse(answer, assessed_sha: "abc1234").valid?
    end

    def test_the_assessment_comment_round_trips_and_neutralizes_markup
      assessment = Assessment.parse(answer(reason: "Ping @someone <b>now</b>\n--> done"), assessed_sha: HEAD)
      body = assessment.markdown(verified: false, command: "/browser-pr-verification 7")

      refute_includes body, " @someone"
      refute_includes body, "<b>"
      assert_equal assessment.to_h, Assessment.latest([ { "body" => body, "user" => { "login" => Assessment::AUTHOR } } ]).to_h
      assert_nil Assessment.latest([ { "body" => "<!-- browser-verification-assessment:%%% -->", "user" => { "login" => Assessment::AUTHOR } } ])
    end

    def test_only_a_plain_login_is_mentioned
      assert_equal "@dev-user ", Markdown.mention("dev-user")
      assert_equal "", Markdown.mention("dependabot[bot]")
      assert_equal "", Markdown.mention("someone here")
      assert_equal "", Markdown.mention(nil)
    end

    def test_a_report_passes_only_when_complete_and_every_case_passed
      assert Report.new(report_data("verified_by" => "dev")).passed?
      refute Report.new(report_data("verified_by" => "dev", "coverage_complete" => false)).passed?
      refute Report.new(report_data("verified_by" => "dev", "cases" => [ { "id" => "A", "name" => "x", "result" => "fail" } ])).passed?
    end

    def test_a_malformed_report_is_invalid_without_raising
      [ [ "not", "an", "object" ], report_data, report_data("verified_by" => "dev", "tested_sha" => "nope"),
        report_data("verified_by" => "dev", "cases" => []),
        report_data("verified_by" => "dev", "cases" => [ { "id" => "A", "name" => "x", "result" => "skipped" } ]),
        report_data("verified_by" => "dev", "cases" => [ { "id" => "A", "name" => "x", "result" => "pass" } ] * 2),
        report_data("verified_by" => "dev", "excluded" => [ { "name" => "x" } ]) ].each do |data|
        refute Report.new(data).valid?, data.inspect
      end
    end

    def test_config_knows_what_is_gated_and_what_cannot_touch_the_browser
      config = Config.new("skip_branch_prefixes" => [ "spike/" ])

      assert config.skip?(author: "dependabot[bot]", branch: "x")
      assert config.skip?(author: "dev", branch: "spike/idea")
      refute config.skip?(author: "dev", branch: "feature/x")
      assert config.ignored?("README.md")
      assert config.ignored?("docs/a/b/c.txt")
      assert config.ignored?(".github/workflows/ci.yml")
      refute config.ignored?("app/views/home.html.erb")
      assert_raises(Error) { Config.new("lable" => "typo") }
    end

    def test_the_model_client_runs_without_tools_and_returns_the_structured_answer
      seen = nil
      runner = lambda do |environment, argv, stdin|
        seen = { environment: environment, argv: argv, stdin: stdin }
        [ JSON.generate(is_error: false, structured_output: { decision: "required" }), "", true ]
      end

      text = ModelClient.new(command: "claude", model: "some-model", runner: runner).complete(system: "rules", user: "pr", schema: { type: "object" })

      assert_equal({ "decision" => "required" }, JSON.parse(text))
      assert_equal "", seen[:argv][seen[:argv].index("--tools") + 1]
      assert_equal "some-model", seen[:argv][seen[:argv].index("--model") + 1]
      assert_nil seen[:environment].fetch("GH_TOKEN")
      [ [ "", "not logged in", false ], [ JSON.generate(is_error: true), "", true ], [ "not json", "", true ] ].each do |outcome|
        assert_raises(Error) { ModelClient.new(command: "claude", runner: ->(*) { outcome }).complete(system: "", user: "", schema: {}) }
      end
      refused = [ JSON.generate(is_error: true, result: "Not logged in"), "", false ]
      error = assert_raises(Error) { ModelClient.new(command: "claude", runner: ->(*) { refused }).complete(system: "", user: "", schema: {}) }
      assert_includes error.message, "Not logged in"
    end

    def test_status_names_the_next_step
      shell = FakeShell.new
      status = ->(github) { Status.new(github: github, shell: shell, probe: ->(_url) { true }).to_h(123).fetch("next") }

      assert_equal "request_assessment", status.call(FakeGitHub.new)
      assert_equal "run_and_publish", status.call(FakeGitHub.new(comments: [ assessment_comment ]))
      assert_equal "nothing", status.call(FakeGitHub.new(comments: [ assessment_comment(decision: "not-required") ]))
      assert_equal "nothing", status.call(FakeGitHub.new(comments: [ assessment_comment, report_comment ], labels: [ "browser-verified" ]))
      assert_equal "check_out_pr_head", status.call(FakeGitHub.new(head: OLD))

      Publisher.new(github: FakeGitHub.new, report_path: report_file, shell: shell).save
      assert_equal "publish_saved", status.call(FakeGitHub.new(comments: [ assessment_comment ]))
      no_pr = FakeGitHub.new
      no_pr.branch_pr = nil
      assert_equal "open_pull_request", Status.new(github: no_pr, shell: shell).to_h.fetch("next")
    end

    def test_status_never_tells_the_agent_to_start_the_app
      config = Config.new("url" => "http://localhost:3000", "start_command" => "bin/dev")
      status = ->(running) { Status.new(github: FakeGitHub.new(comments: [ assessment_comment ]), config: config, shell: FakeShell.new, probe: ->(_url) { running }).to_h(123) }

      assert_equal "run_and_publish", status.call(true).fetch("next")
      stopped = status.call(false)
      assert_equal "ask_to_start_app", stopped.fetch("next")
      assert_equal false, stopped.dig("app", "running")
    end

    def test_the_hook_publishes_a_saved_run_only_after_a_pr_was_opened
      shell = FakeShell.new
      github = FakeGitHub.new
      hook = Hook.new(publisher_factory: -> { Publisher.new(github: github, shell: shell) }, shell: shell)

      assert_nil hook.after('{"tool_input":{"command":"ls"}}')
      assert_nil hook.after('{"tool_input":{"command":"gh pr create --title x"}}')

      Publisher.new(github: github, report_path: report_file, shell: shell).save
      message = hook.after('{"command":"gh pr create --title x"}')
      assert_includes message, "published"
      assert_includes github.writes.map(&:first), :add_label
      assert_equal message, JSON.parse(Hook.render(message, "claude")).dig("hookSpecificOutput", "additionalContext")
      assert_equal message, Hook.render(message, "cursor")
    end
  end
end
