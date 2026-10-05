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
      assert_empty waived.writes
      assert_equal [ "success", "Browser verification waived by lead." ], waived.statuses.last

      own = FakeGitHub.new(comments: [ assessment_comment ], labels: [ "browser-verification-waived" ], reviewers: [ "reviewer" ],
        label_actors: { "browser-verification-waived" => "dev-user" })
      assert_equal :closed, enforce(own)

      allowed = Gate.new(github: own, config: Config.new("waiver_by_author" => true), log: StringIO.new)
      assert_equal :open, allowed.enforce(123)
    end

    def test_says_when_a_published_run_no_longer_covers_the_latest_commits
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment({ "tested_sha" => OLD }) ], reviewers: [ "reviewer" ])

      assert_equal :closed, enforce(github)
      assert_includes github.writes.last.last, "does not cover the latest commits"
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
  end
end
