require "test_helper"

module BrowserReviewGate
  class AssessorTest < Minitest::Test
    include TestData

    def test_writes_the_decision_for_the_head_as_one_comment_with_the_ready_command
      github = FakeGitHub.new
      model = FakeModel.new(answer)

      assessment = assess(github, model)

      assert assessment.required?
      kind, body = github.writes.fetch(0)
      assert_equal :create_comment, kind
      assert_includes body, "```\n/browser-pr-verification 123\n```"
      assert_includes body, "@dev-user **Human review is on hold.** Browser testing is needed"
      assert_includes model.requests.fetch(0)[:user], "show.html.erb"
    end

    def test_does_not_ask_the_model_when_only_ignored_paths_changed
      github = FakeGitHub.new(files: [ { "filename" => "README.md" }, { "filename" => "docs/guide/setup.txt" }, { "filename" => ".github/workflows/ci.yml" } ])
      model = FakeModel.new(answer)

      assessment = assess(github, model)

      refute assessment.required?
      assert_empty model.requests
      assert_includes github.writes.fetch(0).last, "not needed"
      refute_includes github.writes.fetch(0).last, "@dev-user"
    end

    def test_does_not_ask_the_model_again_for_an_assessed_head
      github = FakeGitHub.new(comments: [ assessment_comment(decision: "not-required") ])
      model = FakeModel.new(answer)

      refute assess(github, model).required?
      assert_empty model.requests
      assert_empty github.writes
    end

    def test_a_run_that_passed_every_scenario_keeps_the_label
      github = FakeGitHub.new(comments: [ report_comment ], labels: [ "browser-verified" ])
      model = FakeModel.new(answer)

      assess(github, model)

      assert_equal [ :create_comment ], github.writes.map(&:first)
      assert_includes github.writes.fetch(0).last, "report covers it"
      cases = JSON.parse(model.requests.fetch(0)[:user][/<pull_request>\n(.*)\n<\/pull_request>/m, 1]).fetch("report_cases")
      assert_equal [ "BROWSER-1" ], cases.map { |test_case| test_case["id"] }
    end

    def test_the_comment_lists_the_scenarios_and_ticks_the_ones_a_run_passed
      github = FakeGitHub.new(comments: [ report_comment ])

      assess(github, FakeModel.new(answer(scenarios: [ SIGN_IN, SETTINGS ])))

      body = github.writes.fetch(0).last
      assert_includes body, "- [x] **passed** `BROWSER-1` Sign in and land on the dashboard"
      assert_includes body, "- [ ] **missing** `SETTINGS-1` Change a setting and see it kept"
    end

    def test_a_report_the_decision_has_not_judged_is_shown_to_the_model_once
      github = FakeGitHub.new(comments: [ assessment_comment(scenarios: [ SETTINGS ], id: 7), report_comment ], labels: [ "browser-verified" ])
      model = FakeModel.new(answer(scenarios: [ SETTINGS ]))

      assess(github, model)
      assert_equal 1, model.requests.size
      assert_includes github.writes, [ :remove_label, "browser-verified" ]

      assess(github, model)
      assert_equal 1, model.requests.size
    end

    def test_a_report_from_someone_who_cannot_push_is_ignored
      github = FakeGitHub.new(comments: [ report_comment({}, login: "stranger") ], labels: [ "browser-verified" ])

      assess(github, FakeModel.new(answer))

      assert_includes github.writes, [ :remove_label, "browser-verified" ]
    end

    def test_refreshes_its_comment_without_the_model_when_a_report_arrives_later
      github = FakeGitHub.new(comments: [ assessment_comment(id: 7), report_comment ], labels: [ "browser-verified" ])
      model = FakeModel.new(answer)

      assess(github, model)

      assert_empty model.requests
      kind, id, body = github.writes.fetch(0)
      assert_equal [ :update_comment, 7 ], [ kind, id ]
      assert_includes body, "report covers it"
      refute_includes body, "/browser-pr-verification"
    end

    def test_removes_the_label_when_a_new_commit_is_not_covered_by_the_older_run
      github = FakeGitHub.new(comments: [ report_comment({ "tested_sha" => OLD }) ], labels: [ "browser-verified" ])

      assess(github, FakeModel.new(answer(scenarios: [ SIGN_IN, SETTINGS ])))

      assert_includes github.writes, [ :remove_label, "browser-verified" ]
    end

    def test_a_new_commit_that_owes_a_run_gets_a_new_comment_mentioning_who_pushed_it
      stale = assessment_comment(decision: "not-required", sha: OLD, id: 7)
      github = FakeGitHub.new(comments: [ stale ], commit_author: "teammate")

      assess(github, FakeModel.new(answer))

      assert_equal [ :delete_comment, :create_comment ], github.writes.map(&:first)
      assert_includes github.writes.last.last, "@teammate @dev-user **Human review is on hold.** Browser testing is needed"
    end

    def test_keeps_the_label_when_the_model_finds_the_older_run_still_covers_a_new_commit
      github = FakeGitHub.new(comments: [ report_comment({ "tested_sha" => OLD }) ], labels: [ "browser-verified" ])

      assess(github, FakeModel.new(answer))

      refute_includes github.writes.map(&:first), :remove_label
    end

    def test_a_waived_pr_is_not_assessed_so_a_new_commit_neither_pings_nor_drops_the_label
      github = FakeGitHub.new(comments: [ assessment_comment(sha: OLD) ], labels: [ "browser-verified", "browser-verification-waived" ],
        label_actors: { "browser-verification-waived" => "lead" })
      model = FakeModel.new(answer)

      assert_nil assess(github, model)
      assert_empty model.requests
      assert_empty github.writes

      local = FakeGitHub.new(comments: [ assessment_comment(sha: OLD) ], labels: [ "browser-verified", "browser-verification-waived" ],
        label_actors: { "browser-verification-waived" => "lead" })
      assert_nil Assessor.new(github: local, model: nil, config: Config.new("assessment" => "local"), log: StringIO.new).assess(123)
      assert_empty local.writes
    end

    def test_a_waiver_from_the_author_does_not_stop_the_assessment
      github = FakeGitHub.new(labels: [ "browser-verification-waived" ], label_actors: { "browser-verification-waived" => "dev-user" })

      assert assess(github, FakeModel.new(answer)).required?
      refute_empty github.writes
    end

    def test_an_invalid_model_answer_writes_nothing
      github = FakeGitHub.new

      assert_raises(Error) { assess(github, FakeModel.new('{"decision":"maybe"}')) }
      assert_empty github.writes
    end

    def test_long_patches_are_cut_and_flagged
      github = FakeGitHub.new(files: [ { "filename" => "app/javascript/big.js", "status" => "added", "patch" => "x" * 9_000 } ])
      model = FakeModel.new(answer)

      assess(github, model)

      document = JSON.parse(model.requests.fetch(0)[:user][/<pull_request>\n(.*)\n<\/pull_request>/m, 1])
      file = document.fetch("files").fetch(0)
      assert_equal 8_000, file.fetch("patch").length
      assert file.fetch("patch_truncated")
    end

    private

    def assess(github, model)
      Assessor.new(github: github, model: model, log: StringIO.new).assess(123)
    end
  end
end
