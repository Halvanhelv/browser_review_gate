require "test_helper"

module BrowserReviewGate
  class UnitsTest < Minitest::Test
    include TestData

    def test_an_assessment_answer_that_is_malformed_is_invalid
      [ "not json", answer(decision: "maybe"), answer(reason: "  "), answer(scenarios: []), answer(scenarios: "all"),
        answer(scenarios: [ { id: "has space", name: "x" } ]), answer(scenarios: [ SIGN_IN, SIGN_IN ]),
        answer(scenarios: Array.new(13) { |index| { id: "S-#{index}", name: "x" } }), '["required"]' ].each do |text|
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
        report_data("verified_by" => "dev", "cases" => [ { "id" => "A", "name" => "x", "result" => "maybe" } ]),
        report_data("verified_by" => "dev", "schema_version" => 1), report_data("verified_by" => "dev", "tested_sha" => "abc1234"),
        report_data("verified_by" => "dev", "surprise" => true), report_data("verified_by" => "dev", "tool" => { "name" => "x", "capabilities" => [ "mind-reading" ] }),
        report_data("verified_by" => "dev", "finished_at" => "2026-11-11T09:00:00Z"),
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

    def test_an_api_client_asks_each_provider_in_its_own_shape_and_returns_the_structured_answer
      answer = JSON.generate(decision: "not-required")
      replies = {
        "anthropic" => { content: [ { type: "thinking", thinking: "" }, { type: "text", text: answer } ], stop_reason: "end_turn" },
        "openai" => { choices: [ { message: { content: answer, refusal: nil } } ] },
        "gemini" => { candidates: [ { content: { parts: [ { text: answer } ] } } ] }
      }
      with_env("ANTHROPIC_API_KEY" => "k", "OPENAI_API_KEY" => "k", "GEMINI_API_KEY" => "k") do
        replies.each do |provider, reply|
          seen = nil
          transport = ->(url, headers, body) { seen = [ url, headers, body ] and [ "200", JSON.generate(reply) ] }
          client = ModelApi.new(provider: provider, model: "some-model", transport: transport)

          assert_equal({ "decision" => "not-required" }, JSON.parse(client.complete(system: "rules", user: "pr", schema: { type: "object" })), provider)
          assert_includes JSON.generate(seen), "rules", provider
          assert_includes JSON.generate(seen), "some-model", provider
          refute seen.last.key?(:tools), provider
        end

        declined = ->(*) { [ "200", JSON.generate(stop_reason: "refusal", content: []) ] }
        assert_raises(Error) { ModelApi.new(provider: "anthropic", transport: declined).complete(system: "", user: "", schema: {}) }
        failed = ->(*) { [ "401", JSON.generate(error: { message: "bad key" }) ] }
        error = assert_raises(Error) { ModelApi.new(provider: "openai", model: "m", transport: failed).complete(system: "", user: "", schema: {}) }
        assert_includes error.message, "bad key"
      end
      assert_raises(Error) { ModelApi.new(provider: "gemini") }
      assert_raises(Error) { ModelApi.new(provider: "other") }
    end

    def test_the_credentials_at_hand_choose_who_assesses_and_the_cli_stays_the_default
      choose = ->(settings, environment) { ModelClient.for(Config.new(settings), environment: environment).class }

      assert_equal ModelClient, choose.call({}, {})
      assert_equal ModelClient, choose.call({}, { "ANTHROPIC_API_KEY" => "k", "OPENAI_API_KEY" => "k" })
      assert_equal ModelApi, choose.call({ "model" => "m" }, { "OPENAI_API_KEY" => "k" })
      assert_equal ModelApi, choose.call({ "provider" => "anthropic" }, { "CLAUDE_CODE_OAUTH_TOKEN" => "k" })
    end

    def test_stats_count_what_the_gate_did
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment({ "failed_runs" => 1, "runs" => 2 }) ])
      github.define_singleton_method(:pull_requests_updated_since) do |_date|
        [ { "number" => 1, "state" => "closed", "labels" => [ { "name" => "browser-verified" } ] }, { "number" => 2, "state" => "open", "labels" => [] } ]
      end

      counts = Stats.new(github: github).to_h(since: "2026-01-01")

      assert_equal({ "pull_requests" => 2, "assessed" => 2, "required" => 2, "verified" => 1, "waived" => 0, "owed" => 1, "found_a_failure" => 2,
        "runs" => 4, "failed_runs" => 2 }, counts.slice(*Stats::COUNTS))
      assert_nil counts["hours_to_verification"], "PRs without created_at are not measured"
      assert_equal 0, counts.dig("assessment_usage", "assessments_with_cost")
    end

    def test_status_lists_the_scenarios_still_to_run
      github = FakeGitHub.new(comments: [ assessment_comment(scenarios: [ SIGN_IN, SETTINGS ]), report_comment ])

      status = Status.new(github: github, shell: FakeShell.new, probe: ->(_url) { true }).to_h(123)

      assert_equal [ { "id" => "SETTINGS-1", "name" => "Change a setting and see it kept", "priority" => "normal", "status" => "missing" } ],
        status.fetch("scenarios")
      assert_equal "run_and_publish", status.fetch("next")
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
      config = Config.new("environments" => { "local" => { "url" => "http://localhost:3000", "start_command" => "bin/dev" } })
      status = ->(running) { Status.new(github: FakeGitHub.new(comments: [ assessment_comment ]), config: config, shell: FakeShell.new, probe: ->(_url) { running }).to_h(123) }

      assert_equal "run_and_publish", status.call(true).fetch("next")
      stopped = status.call(false)
      assert_equal "ask_to_start_app", stopped.fetch("next")
      assert_equal false, stopped.dig("environment", "reachable")
    end

    def with_env(values)
      before = values.keys.to_h { |name| [ name, ENV[name] ] }
      values.each { |name, value| ENV[name] = value }
      yield
    ensure
      before.each { |name, value| ENV[name] = value }
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
