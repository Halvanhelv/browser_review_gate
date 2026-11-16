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

    def test_a_case_that_fails_and_then_passes_on_the_same_commit_counts_and_is_marked_flaky
      merged = rerun("fail", "pass")

      assert_equal "passed", merged.status_of("BROWSER-1")
      assert merged.flaky?("BROWSER-1")
      assert merged.passed?
      assert_includes merged.markdown, 'PASSED \(flaky: results differed on this commit\)'
    end

    def test_a_case_that_passes_and_then_fails_on_the_same_commit_still_blocks
      merged = rerun("pass", "fail")

      assert_equal "failed", merged.status_of("BROWSER-1")
      assert merged.flaky?("BROWSER-1")
      refute merged.passed?
    end

    def test_a_case_that_fails_on_one_commit_and_passes_on_the_next_is_a_fix_not_a_flake
      refute rerun("fail", "pass", first_sha: OLD).flaky?("BROWSER-1")
      refute rerun("pass", "pass").flaky?("BROWSER-1")
    end

    def test_the_flaky_mark_stays_with_the_commit_it_was_seen_on
      flaky = rerun("fail", "pass")
      again = Report.merge(flaky.to_h, attempt("pass"))
      untouched = Report.merge(flaky.to_h, attempt("pass", id: "BROWSER-2"))
      moved_on = Report.merge(flaky.to_h, attempt("pass", sha: "c" * 40))

      assert again.flaky?("BROWSER-1"), "the same commit stays flaky"
      assert untouched.flaky?("BROWSER-1"), "a case that was not run again keeps its mark"
      refute moved_on.flaky?("BROWSER-1"), "a run on another commit starts clean"
    end

    def test_only_the_gem_marks_a_case_flaky
      submitted = report(browser_case("BROWSER-1", "Sign in").merge("flaky" => true))

      assert_includes submitted.submission_errors.join, "flaky is set by the gem"
      refute report(browser_case("BROWSER-1", "Sign in").merge("flaky" => "yes")).valid?
    end

    private

    def attempt(result, id: "BROWSER-1", sha: HEAD)
      report_data("tested_sha" => sha, "verified_by" => "dev", "cases" => [ browser_case(id, "Sign in", result: result) ])
    end

    def rerun(first, second, first_sha: HEAD)
      Report.merge(Report.merge({}, attempt(first, sha: first_sha)).to_h, attempt(second))
    end

    def case_with(evidence) = browser_case("BROWSER-1", "Sign in").merge("evidence" => evidence)

    def report(test_case, config = Config.new, overrides = {})
      cases = test_case ? { "cases" => [ test_case ] } : {}
      Report.new(report_data(cases.merge(overrides)).merge("verified_by" => "dev"), config: config)
    end
  end
end
