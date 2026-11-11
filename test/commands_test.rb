require "test_helper"

module BrowserReviewGate
  class CommandsTest < Minitest::Test
    include TestData

    MANDATORY = { "scenarios" => { "matrix" => { "viewport" => %w[desktop mobile] },
      "mandatory" => [ { "id" => "CHECKOUT", "name" => "Pay for an order", "paths" => [ "app/views/checkout/**" ], "matrix" => true } ] } }.freeze

    # --- assessment ---

    def test_mandatory_scenarios_are_added_and_force_a_run_for_their_paths
      github = FakeGitHub.new(files: [ { "filename" => "app/views/checkout/show.html.erb", "status" => "modified", "patch" => "+x" } ])
      model = FakeModel.new(answer(decision: "not-required"))

      assessment = Assessor.new(github: github, model: model, config: Config.new(MANDATORY), log: StringIO.new).assess(123)

      assert assessment.required?
      assert_equal Assessor::MANDATORY_REASON, assessment.reason
      assert_equal %w[CHECKOUT.desktop CHECKOUT.mobile], assessment.scenarios.map { |scenario| scenario["id"] }
      assert(assessment.scenarios.all? { |scenario| scenario["priority"] == "critical" })
    end

    def test_mandatory_scenarios_are_added_even_when_ignored_paths_would_skip_the_model
      config = Config.new(MANDATORY.merge("ignore_paths" => [ "app/views/checkout/**" ]))
      github = FakeGitHub.new(files: [ { "filename" => "app/views/checkout/show.html.erb", "status" => "modified", "patch" => "+x" } ])

      assert Assessor.new(github: github, model: FakeModel.new(answer(decision: "not-required")), config: config, log: StringIO.new).assess(123).required?
    end

    def test_the_model_cannot_exceed_the_scenario_limit
      config = Config.new("scenarios" => { "max_count" => 2 })
      model = FakeModel.new(answer(scenarios: Array.new(3) { |index| { id: "S-#{index}", name: "Scenario #{index}" } }))

      error = assert_raises(Error) { Assessor.new(github: FakeGitHub.new, model: model, config: config, log: StringIO.new).assess(123) }
      assert_includes error.message, "at most 2"
      assert_includes model.requests.first[:system], "at most 2"
    end

    def test_reported_usage_is_kept_and_nothing_is_estimated
      model = FakeModel.new(answer)
      model.define_singleton_method(:last_usage) { { "provider" => "openai", "model" => "m", "input_tokens" => 900, "output_tokens" => 80 } }

      assessment = Assessor.new(github: FakeGitHub.new, model: model, log: StringIO.new).assess(123)
      assert_equal 900, assessment.usage["input_tokens"]
      refute assessment.usage.key?("cost_usd")
    end

    def test_model_clients_read_usage_from_the_provider_answer
      runner = ->(_env, _argv, _stdin) { [ JSON.generate(is_error: false, structured_output: { decision: "not-required" }, usage: { input_tokens: 10, output_tokens: 2 }, total_cost_usd: 0.01), "", true ] }
      cli = ModelClient.new(command: "claude", runner: runner)
      cli.complete(system: "s", user: "u", schema: {})
      assert_equal({ "provider" => "claude-cli", "input_tokens" => 10, "output_tokens" => 2, "cost_usd" => 0.01 }, cli.last_usage)

      transport = ->(_url, _headers, _body) { [ 200, JSON.generate(choices: [ { message: { content: "{\"a\":1}" } } ], usage: { prompt_tokens: 5, completion_tokens: 1 }, model: "m-1") ] }
      api = ModelApi.new(provider: "openai", model: "m", transport: transport)
      with_env("OPENAI_API_KEY" => "k") { api.complete(system: "s", user: "u", schema: {}) }
      assert_equal({ "provider" => "openai", "model" => "m-1", "input_tokens" => 5, "output_tokens" => 1 }, api.last_usage)
    end

    # --- verify ---

    def test_verify_says_what_to_run_and_exits_with_a_meaningful_status
      config = Config.new("environments" => { "local" => { "url" => "http://localhost:3000", "healthcheck" => "/up" } })
      probed = []
      verify = verify(FakeGitHub.new(comments: [ assessment_comment ]), config, probe: ->(url) { probed << url; false })

      outcome, status = verify.run(number: 123)
      assert_equal "ask_to_start_app", outcome
      assert_equal 3, Verify.exit_status(outcome)
      assert_equal [ "http://localhost:3000/up" ], probed
      assert_includes Verify.describe(outcome, status), "do not start it yourself"

      outcome, status = verify(FakeGitHub.new(comments: [ assessment_comment ]), config).run(number: 123)
      assert_equal [ "run_and_publish", 2 ], [ outcome, Verify.exit_status(outcome) ]
      assert_includes Verify.describe(outcome, status), "BROWSER-1 [missing]"
    end

    def test_verify_requests_a_missing_assessment
      github = FakeGitHub.new

      outcome, = verify(github, Config.new).run(number: 123)
      assert_equal [ "assessment_requested", 4 ], [ outcome, Verify.exit_status(outcome) ]
      assert_includes github.writes, [ :dispatch, "browser-review-gate.yml", 123 ]

      outcome, = verify(FakeGitHub.new, Config.new).run(number: 123, request: false)
      assert_equal "request_assessment", outcome
    end

    def test_verify_publishes_a_finished_run_and_reports_when_nothing_is_left
      github = FakeGitHub.new(comments: [ assessment_comment ])
      outcome, = verify(github, Config.new).run(number: 123, report: report_file)
      assert_equal [ "published", 0 ], [ outcome, Verify.exit_status(outcome) ]
      assert_includes github.labels, "browser-verified"

      outcome, = verify(github, Config.new).run(number: 123)
      assert_equal "nothing", outcome
    end

    def test_verify_rejects_an_unknown_environment
      assert_raises(Error) { verify(FakeGitHub.new(comments: [ assessment_comment ]), Config.new).run(number: 123, environment: "staging") }
    end

    # --- stats ---

    def test_stats_measure_time_to_verification_and_sum_reported_usage
      usage = { "provider" => "claude-cli", "input_tokens" => 1000, "output_tokens" => 100, "cost_usd" => 0.02 }
      assessment = Assessment.parse(answer, assessed_sha: HEAD, usage: usage)
      comment = { "id" => 1, "body" => assessment.markdown(verified: true, command: "x"), "user" => { "login" => Assessment::AUTHOR } }
      failing = report_comment({ "cases" => [ browser_case("BROWSER-1", "Sign in"), browser_case("CHECKOUT", "Pay", result: "fail") ] })
        .merge("updated_at" => "2026-11-02T12:00:00Z")
      github = FakeGitHub.new(comments: [ comment, failing ])
      github.define_singleton_method(:pull_requests_updated_since) do |_date|
        [ { "number" => 1, "state" => "open", "created_at" => "2026-11-02T08:00:00Z", "labels" => [ { "name" => "browser-verified" } ] } ]
      end

      result = Stats.new(github: github).to_h(since: "2026-11-01")

      assert_equal({ "median" => 4.0, "measured" => 1 }, result["hours_to_verification"])
      assert_equal({ "CHECKOUT" => 1 }, result["failing_scenarios"])
      assert_equal 1000, result.dig("assessment_usage", "input_tokens")
      assert_equal 0.02, result.dig("assessment_usage", "cost_usd")
      assert_includes Stats.text(result, 30), "reported by the provider"
    end

    # --- CLI ---

    def test_cli_verify_speaks_json_and_exits_with_the_outcome
      github = FakeGitHub.new(comments: [ assessment_comment ])
      out = StringIO.new
      cli = CLI.new([ "verify", "--pr", "123", "--json", "--no-request" ], stdout: out, github: github, config: Config.new, shell: FakeShell.new)
      cli.define_singleton_method(:root) { Dir.mktmpdir }
      assert_equal 2, cli.run
      parsed = JSON.parse(out.string)
      assert_equal "run_and_publish", parsed["outcome"]
      assert_equal [ "BROWSER-1" ], parsed["scenarios"].map { |scenario| scenario["id"] }
    end

    # --- doctor ---

    def test_doctor_reports_pass_warn_fail_and_skip_without_claiming_what_it_cannot_see
      root = Dir.mktmpdir
      Installer.new(root: root, log: StringIO.new, agents: [ "claude" ]).install
      shell = DoctorShell.new(push: "true", secrets: "OPENAI_API_KEY\n", protection: nil)

      checks = Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { false }).checks.to_h { |check| [ check.name, check] }

      assert_equal "PASS", checks.fetch("ruby").status
      assert_equal "PASS", checks.fetch("gh").status
      assert_equal "PASS", checks.fetch("repository access").status
      assert_equal "WARN", checks.fetch("environment local").status
      assert_equal "PASS", checks.fetch("agent claude").status
      assert_equal "SKIP", checks.fetch("browser tool").status
      assert_equal "SKIP", checks.fetch("required check").status
      assert_equal "PASS", checks.fetch("model credentials").status
      assert_equal "PASS", checks.fetch("labels").status
      json = JSON.parse(Doctor.json(checks.values))
      refute_includes Doctor.json(checks.values), "sk-"
      assert json.key?("ok")
    end

    def test_doctor_checks_the_revision_header_when_traces_are_checked
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, ".github"))
      File.write(File.join(root, Config::PATH), "environments:\n  local:\n    url: http://localhost:3000\nprovenance:\n  trace: require\n")
      shell = DoctorShell.new
      shell.define_singleton_method(:head) { "a" * 40 }
      status = ->(served) { Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { true }, header_probe: ->(_url, _name) { served })
        .checks.find { |check| check.name == "revision header local" }.status }

      assert_equal "FAIL", status.call(nil)
      recording = Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { true }, header_probe: ->(_url, _name) { nil })
        .checks.find { |check| check.name == "trace recording" }
      assert_equal "WARN", recording.status
      File.write(File.join(root, ".mcp.json"), JSON.generate(mcpServers: { playwright: { command: "npx" } }))
      assert_equal "PASS", Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { true }, header_probe: ->(_url, _name) { nil })
        .checks.find { |check| check.name == "trace recording" }.status
      assert_equal "PASS", status.call("a" * 12)
      assert_equal "WARN", status.call("b" * 40)
    end

    def test_doctor_names_a_missing_waiver_label_and_how_to_create_it
      root = Dir.mktmpdir
      Installer.new(root: root, log: StringIO.new, agents: [ "claude" ]).install
      shell = DoctorShell.new(labels: [ "browser-verified" ])

      check = Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { false }).checks.find { |item| item.name == "labels" }

      assert_equal "FAIL", check.status
      assert_includes check.message, "browser-verification-waived"
      assert_includes check.fix, "gh label create browser-verification-waived"
      refute_includes check.fix, "gh label create browser-verified "
    end

    def test_doctor_fails_without_gh_and_on_broken_settings
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, ".github"))
      File.write(File.join(root, Config::PATH), "environments: [oops]\n")
      checks = Doctor.new(root: root, shell: DoctorShell.new(gh: false), probe: ->(_url) { true }).checks

      assert_equal "FAIL", checks.find { |check| check.name == "settings" }.status
      assert_equal "FAIL", checks.find { |check| check.name == "gh" }.status
      assert_includes Doctor.text(checks), "fix:"
    end

    private

    def verify(github, config, probe: ->(_url) { true })
      Verify.new(github: github, config: config, prompts: Prompts.new(Dir.mktmpdir), shell: FakeShell.new, probe: probe)
    end

    def with_env(values)
      saved = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
  end
end
