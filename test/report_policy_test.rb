require "test_helper"

module BrowserReviewGate
  # What counts as a passing case under the project's policy, and which commits a case may come from.
  class ReportPolicyTest < Minitest::Test
    include TestData

    SCREENSHOT = { "kind" => "screenshot", "name" => "home.png", "media_type" => "image/png", "bytes" => 10, "sha256" => "a" * 64 }.freeze

    def test_console_and_network_errors_fail_a_passing_case_when_the_project_says_so
      noisy = case_with("console_errors" => [ "TypeError: x is undefined" ], "network_errors" => [])
      strict = Config.new("verification" => { "fail_on_console_errors" => true })

      assert_equal "passed", report(noisy).status_of("BROWSER-1")
      assert_equal "failed", report(noisy, strict).status_of("BROWSER-1")
      refute report(noisy, strict).passed?
      assert_includes report(noisy, strict).markdown, "console errors were reported"
    end

    def test_required_evidence_applies_only_to_what_the_tool_can_produce
      config = Config.new("gate" => { "require_evidence" => true }, "evidence" => { "screenshots" => "always", "trace" => "always" })
      without = case_with("console_errors" => [], "network_errors" => [])
      with = case_with("files" => [ SCREENSHOT ], "console_errors" => [], "network_errors" => [])

      assert_equal "failed", report(without, config).status_of("BROWSER-1")
      assert_equal "passed", report(with, config).status_of("BROWSER-1"), "the tool has no trace capability, so no trace is asked for"
      blind = report(without, config, "tool" => { "name" => "Text browser", "capabilities" => [] })
      assert_equal "passed", blind.status_of("BROWSER-1")
      assert_includes report(without, config).submission_errors.join, "has no screenshot"
    end

    def test_console_and_network_logs_must_be_stated_when_required
      config = Config.new("gate" => { "require_evidence" => true }, "evidence" => { "console_logs" => true, "network_logs" => true })

      assert_includes report(case_with({}), config).submission_errors.join, "console errors"
      assert_empty report(case_with("console_errors" => [], "network_errors" => []), config).submission_errors
    end

    def test_skipped_and_blocked_cases_need_a_reason_and_never_pass
      blocked = browser_case("BROWSER-1", "Sign in", result: "blocked").merge("reason" => "The OAuth provider is not reachable locally.")

      assert_equal "blocked", report(blocked).status_of("BROWSER-1")
      assert_empty report(blocked).submission_errors
      assert_includes report(blocked.except("reason")).submission_errors.join, "needs a reason"
      refute Assessment.parse(answer, assessed_sha: HEAD).covered_by?(report(blocked))
    end

    def test_failures_outside_the_scenarios_block_only_when_the_project_says_so
      cases = [ browser_case("BROWSER-1", "Sign in"), browser_case("EXTRA-1", "Something else", result: "fail") ]
      assessment = Assessment.parse(answer, assessed_sha: HEAD)

      refute assessment.covered_by?(report(nil, Config.new, "cases" => cases))
      assert assessment.covered_by?(report(nil, Config.new("gate" => { "block_on_failure" => false }), "cases" => cases))
    end

    def test_only_cases_tested_on_a_commit_of_the_pr_count
      assessment = Assessment.parse(answer, assessed_sha: HEAD)
      elsewhere = report(nil, Config.new, "tested_sha" => "c" * 40)

      refute assessment.covered_by?(elsewhere, commits: [ OLD, HEAD ])
      assert_equal "stale", elsewhere.status_of("BROWSER-1", commits: [ OLD, HEAD ])
      assert assessment.covered_by?(report(nil, Config.new, "tested_sha" => OLD), commits: [ OLD, HEAD ])
      refute assessment.covered_by?(report(nil, Config.new, "tested_sha" => OLD), commits: [ OLD, HEAD ], reuse_passing: false)
    end

    def test_a_forged_marker_with_an_unknown_shape_counts_for_nothing
      data = report_data("verified_by" => "dev", "cases" => [ browser_case("BROWSER-1", "x").merge("evidence" => { "files" => [ SCREENSHOT.merge("source" => "/etc/passwd") ] }) ])
      refute Report.new(data).valid?

      body = "<!-- browser-verification-report:#{Marker.encode(JSON.generate(data))} -->"
      assert_nil Report.latest([ { "body" => body, "user" => { "login" => "dev-user" } } ])
    end

    def test_evidence_links_in_a_stored_report_cannot_inject_markup
      data = report_data("verified_by" => "dev", "cases" => [ browser_case("BROWSER-1", "x").merge("evidence" => { "links" => [ "https://x.test/a)<b>" ] }) ])

      refute Report.new(data).valid?
    end

    private

    def case_with(evidence) = browser_case("BROWSER-1", "Sign in").merge("evidence" => evidence)

    def report(test_case, config = Config.new, overrides = {})
      cases = test_case ? { "cases" => [ test_case ] } : {}
      Report.new(report_data(cases.merge(overrides)).merge("verified_by" => "dev"), config: config)
    end
  end
end
