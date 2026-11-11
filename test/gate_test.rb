require "test_helper"

module BrowserReviewGate
  class GateTest < Minitest::Test
    include TestData

    def test_leaves_the_request_when_no_browser_run_is_needed
      github = FakeGitHub.new(comments: [ assessment_comment(decision: "not-required") ], reviewers: [ "reviewer" ])

      assert_equal :open, enforce(github)
      assert_empty github.writes
    end

    def test_leaves_the_request_when_the_run_is_published_and_labelled
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment ], labels: [ "browser-verified" ], reviewers: [ "reviewer" ])

      assert_equal :open, enforce(github)
      assert_empty github.writes
    end

    def test_takes_back_requests_explains_with_the_ready_command_and_reports_a_pending_status
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "reviewer" ], teams: [ "backend" ])

      assert_equal :closed, enforce(github)
      assert_includes github.writes, [ :remove_reviewers, [ "reviewer" ], [ "backend" ] ]
      assert_includes github.writes.last.last, "@dev-user Review request paused."
      assert_includes github.writes.last.last, "Run `/browser-pr-verification 123`"
      assert_includes github.writes.last.last, "reviewer, backend will be asked again automatically"
      assert_equal [ "pending", "Browser run needed: /browser-pr-verification 123" ], github.statuses.last
    end

    def test_asks_the_same_people_again_once_the_run_is_published
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "reviewer" ]).comment_as(Assessment::AUTHOR)
      enforce(github)
      assert_empty github.reviewers

      github.comments_list << report_comment
      github.labels << "browser-verified"
      assert_equal :open, enforce(github)

      assert_equal [ "reviewer" ], github.reviewers
      assert_includes github.writes.last.last, "@dev-user Review requested again from reviewer"
      assert_equal "success", github.statuses.last.first

      writes_before = github.writes.size
      enforce(github)
      assert_equal writes_before, github.writes.size
    end

    def test_does_not_ask_again_someone_who_reviewed_the_latest_commit_while_review_was_paused
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "approver", "decliner", "stale", "commenter" ])
        .comment_as(Assessment::AUTHOR)
      enforce(github)
      github.reviews_list.push(review("approver", "APPROVED"), review("decliner", "CHANGES_REQUESTED"),
        review("stale", "APPROVED", sha: "0" * 40), review("commenter", "COMMENTED"))

      github.comments_list << report_comment
      github.labels << "browser-verified"
      assert_equal :open, enforce(github)

      assert_equal [ "stale", "commenter" ], github.reviewers
      assert_includes github.writes.last.last, "Review requested again from stale, commenter"
      assert_includes github.writes.last.last, "approver, decliner already reviewed the latest commit"
    end

    def test_asks_nobody_when_everyone_paused_has_reviewed_the_latest_commit
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "approver" ]).comment_as(Assessment::AUTHOR)
      enforce(github)
      github.reviews_list << review("approver", "APPROVED")

      github.comments_list << report_comment
      github.labels << "browser-verified"
      enforce(github)

      assert_empty github.reviewers
      refute(github.writes.any? { |write| write.first == :request_reviewers })
      assert_includes github.writes.last.last, "approver already reviewed the latest commit"

      writes_before = github.writes.size
      enforce(github)
      assert_equal writes_before, github.writes.size
    end

    def test_keeps_one_notice_and_remembers_everyone_across_repeated_requests
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "first" ]).comment_as(Assessment::AUTHOR)
      enforce(github)
      github.request_reviewers(123, reviewers: [ "second" ], team_reviewers: [])
      enforce(github)

      notices = github.comments_list.select { |comment| comment["body"].match?(Gate::PAUSED) }
      assert_equal 1, notices.size
      assert_includes notices.first["body"], "first, second will be asked again"
    end

    def test_a_waiver_from_someone_else_opens_review_and_one_from_the_author_does_not
      waived = FakeGitHub.new(comments: [ assessment_comment ], labels: [ "browser-verification-waived" ], reviewers: [ "reviewer" ],
        label_actors: { "browser-verification-waived" => "lead" })
      assert_equal :open, enforce(waived)
      assert_equal [ "success", "Browser verification waived by lead." ], waived.statuses.last

      own = FakeGitHub.new(comments: [ assessment_comment ], labels: [ "browser-verification-waived" ], reviewers: [ "reviewer" ],
        label_actors: { "browser-verification-waived" => "dev-user" })
      assert_equal :closed, enforce(own)

      allowed = Gate.new(github: own, config: Config.new("waiver_by_author" => true), log: StringIO.new)
      assert_equal :open, allowed.enforce(123)
    end

    def test_a_waiver_says_so_in_one_comment_and_the_comment_goes_when_the_label_does
      github = FakeGitHub.new(comments: [ assessment_comment ], labels: [ "browser-verification-waived" ],
        label_actors: { "browser-verification-waived" => "lead" }).comment_as(Assessment::AUTHOR)

      enforce(github)
      notice = github.comments_list.find { |comment| comment["body"].match?(Gate::WAIVED) }
      assert_includes notice["body"], "Browser verification waived by lead"
      assert_includes notice["body"], "Later pushes do not hold review"
      assert_includes notice["body"], "Remove the `browser-verification-waived` label"

      writes_before = github.writes.size
      enforce(github)
      assert_equal writes_before, github.writes.size

      github.labels.delete("browser-verification-waived")
      assert_equal :closed, enforce(github)
      assert_includes github.writes, [ :delete_comment, notice["id"] ]
      refute(github.comments_list.any? { |comment| comment["body"].match?(Gate::WAIVED) })
    end

    def test_a_waiver_asks_again_the_people_whose_requests_were_taken_back
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "reviewer" ], teams: [ "backend" ],
        label_actors: { "browser-verification-waived" => "lead" }).comment_as(Assessment::AUTHOR)
      assert_equal :closed, enforce(github)
      assert_empty github.reviewers

      github.labels << "browser-verification-waived"
      assert_equal :open, enforce(github)

      assert_equal [ "reviewer" ], github.reviewers
      assert_includes github.writes, [ :request_reviewers, [ "reviewer" ], [ "backend" ] ]
      assert(github.comments_list.any? { |comment| comment["body"].include?("Review requested again from reviewer, backend") })
      assert(github.comments_list.any? { |comment| comment["body"].match?(Gate::WAIVED) })
    end

    def test_says_when_a_published_run_no_longer_covers_the_latest_commits
      github = FakeGitHub.new(comments: [ assessment_comment(scenarios: [ SIGN_IN, SETTINGS ]), report_comment({ "tested_sha" => OLD }) ],
        labels: [ "browser-verified" ], reviewers: [ "reviewer" ])

      assert_equal :closed, enforce(github)
      assert_includes github.writes.last.last, "does not cover the latest commits"
    end

    def test_a_report_from_someone_who_cannot_push_does_not_open_review
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment({}, login: "stranger") ], labels: [ "browser-verified" ], reviewers: [ "reviewer" ])

      assert_equal :closed, enforce(github)
    end

    def test_a_decision_written_before_scenarios_existed_still_counts
      legacy = { "assessed_sha" => HEAD, "decision" => "required", "reason" => "A view changed.", "covered_by_report" => true }
      body = "<!-- browser-verification-assessment:#{Marker.encode(JSON.generate(legacy))} -->"
      comment = { "id" => 1, "body" => body, "user" => { "login" => Assessment::AUTHOR } }
      github = FakeGitHub.new(comments: [ comment, report_comment({ "tested_sha" => OLD }) ], labels: [ "browser-verified" ], reviewers: [ "reviewer" ])

      assert_equal :open, enforce(github)
    end

    def test_a_label_without_a_passing_report_does_not_open_review
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment({ "coverage_complete" => false }) ],
        labels: [ "browser-verified" ], reviewers: [ "reviewer" ])

      assert_equal :closed, enforce(github)
    end

    def test_an_assessment_for_an_older_commit_or_from_another_author_does_not_count
      [ assessment_comment(decision: "not-required", sha: OLD), assessment_comment(decision: "not-required", login: "dev-user") ].each do |comment|
        github = FakeGitHub.new(comments: [ comment ], reviewers: [ "reviewer" ])

        assert_equal :closed, enforce(github)
        assert_includes github.writes.last.last, "not available"
      end
    end

    def test_does_nothing_without_pending_requests
      idle = FakeGitHub.new(comments: [ assessment_comment ])

      assert_equal :closed, enforce(idle)
      assert_empty idle.writes
    end

    private

    def enforce(github) = Gate.new(github: github, log: StringIO.new).enforce(123)

    def review(login, state, sha: HEAD) = { "user" => { "login" => login }, "state" => state, "commit_id" => sha }
  end
end
