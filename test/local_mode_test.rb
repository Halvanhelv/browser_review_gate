require "test_helper"

module BrowserReviewGate
  # `assessment: local`: no model in CI; the author's agent chooses the scenarios.
  class LocalModeTest < Minitest::Test
    include TestData

    VIEW = { "filename" => "app/views/home.html.erb", "status" => "modified", "patch" => "+x" }.freeze
    DOC = { "filename" => "docs/notes.md", "status" => "modified", "patch" => "+x" }.freeze
    LOCAL = { "assessment" => "local" }.freeze

    def test_ci_calls_no_model_and_owes_a_run_for_anything_beyond_ignored_paths
      github = FakeGitHub.new(files: [ VIEW ], reviewers: [ "reviewer" ]).comment_as(Assessment::AUTHOR)
      out = StringIO.new
      assert_equal 0, CLI.new([ "ci", "123" ], stdout: out, github: github, config: Config.new(LOCAL)).run

      assessment = Assessment.latest(github.comments_list)
      assert assessment.required?
      assert assessment.local?
      assert_empty assessment.scenarios
      assert_empty github.reviewers, "review is held until a run is published"
      assert_includes github.comments_list.first["body"], "author's AI agent chooses the scenarios"
    end

    def test_a_docs_only_change_needs_no_run
      github = FakeGitHub.new(files: [ DOC ]).comment_as(Assessment::AUTHOR)
      CLI.new([ "ci", "123" ], stdout: StringIO.new, github: github, config: Config.new(LOCAL)).run

      refute Assessment.latest(github.comments_list).required?
    end

    def test_mandatory_scenarios_are_listed_and_must_pass
      config = Config.new(LOCAL.merge("scenarios" => { "mandatory" => [ { "id" => "HOME", "name" => "Open the home page" } ] }))
      assessment = Assessor.new(github: FakeGitHub.new(files: [ VIEW ]), model: nil, config: config, log: StringIO.new).assess(123)

      assert_equal [ "HOME" ], assessment.scenarios.map { |scenario| scenario["id"] }
      refute assessment.covered_by?(report(config), commits: [ HEAD ])
      assert assessment.covered_by?(report(config, "cases" => [ browser_case("HOME", "Home") ]), commits: [ HEAD ])
    end

    def test_any_passing_case_of_the_agent_covers_the_change_when_fresh
      assessment = Assessment.local(assessed_sha: HEAD, mandatory: [])

      assert assessment.covered_by?(report, commits: [ HEAD ], fresh: true)
      refute assessment.covered_by?(report, commits: [ HEAD ], fresh: false)
      refute assessment.covered_by?(report(Config.new(LOCAL), "coverage_complete" => false), commits: [ HEAD ])
    end

    def test_a_run_stays_fresh_only_across_ignored_changes
      github = FakeGitHub.new
      github.changed_since = { OLD => [ "docs/a.md", "test/x_test.rb" ] }
      old_run = report(Config.new(LOCAL), "tested_sha" => OLD)
      freshness = Freshness.new(github: github, config: Config.new(LOCAL))

      assert freshness.fresh?(old_run, HEAD)
      github.changed_since = { OLD => [ "docs/a.md", "app/views/home.html.erb" ] }
      refute freshness.fresh?(old_run, HEAD)
      assert freshness.fresh?(report, HEAD)
      refute freshness.fresh?(nil, HEAD)
    end

    def test_the_gate_reopens_review_after_a_stale_run_only_when_a_new_run_is_published
      github = FakeGitHub.new(files: [ VIEW ], reviewers: [ "reviewer" ], labels: [ "browser-verified" ],
        comments: [ report_comment({ "tested_sha" => OLD }) ]).comment_as(Assessment::AUTHOR)
      github.changed_since = { OLD => [ "app/views/home.html.erb" ] }
      config = Config.new(LOCAL)

      CLI.new([ "ci", "123" ], stdout: StringIO.new, github: github, config: config).run
      assert_empty github.reviewers

      github.comments_list << report_comment({}, id: 50)
      github.labels << "browser-verified" unless github.labels.include?("browser-verified")
      CLI.new([ "ci", "123" ], stdout: StringIO.new, github: github, config: config).run
      assert_equal [ "reviewer" ], github.reviewers
    end

    def test_the_agent_may_say_no_run_is_needed_with_a_reason_shown_in_the_pr
      config = Config.new(LOCAL)
      declared = report(config, "cases" => [], "coverage_complete" => false, "not_required" => { "reason" => "Only a background job changed; no page shows its result." })

      assert declared.valid?, declared.errors.inspect
      assert Assessment.local(assessed_sha: HEAD, mandatory: []).covered_by?(declared, commits: [ HEAD ], fresh: true)
      refute Assessment.local(assessed_sha: HEAD, mandatory: [ { "id" => "HOME", "name" => "Home" } ]).covered_by?(declared, commits: [ HEAD ], fresh: true)
      assert_includes declared.markdown, "judged that no browser run is needed"
      refute Report.new(report_data("verified_by" => "dev", "cases" => [], "not_required" => { "reason" => " " })).valid?
    end

    def test_a_declaration_never_covers_a_ci_assessment
      declared = report(Config.new, "cases" => [], "not_required" => { "reason" => "Nothing visible changed." })

      refute Assessment.parse(answer, assessed_sha: HEAD).covered_by?(declared, commits: [ HEAD ])
    end

    def test_status_decides_locally_and_doctor_skips_the_secret
      github = FakeGitHub.new(files: [ VIEW ])
      status = Status.new(github: github, config: Config.new(LOCAL), shell: FakeShell.new, probe: ->(_url) { true }).to_h(123)

      assert_equal "local", status["assessment"]
      assert_equal "run_and_publish", status["next"]
      assert_includes Verify.describe("run_and_publish", status), "not_required"

      shell = DoctorShell.new(secrets: "")
      root = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(root, ".github"))
      File.write(File.join(root, Config::PATH), "assessment: local\n")
      check = Doctor.new(root: root, shell: shell, github: FakeGitHub.new, probe: ->(_url) { true }).checks.find { |entry| entry.name == "model credentials" }
      assert_equal "SKIP", check.status
    end

    private

    def report(config = Config.new(LOCAL), overrides = {})
      Report.new(report_data(overrides).merge("verified_by" => "dev"), config: config)
    end
  end
end
