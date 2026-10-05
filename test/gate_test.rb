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

    def test_takes_back_requests_and_explains_with_the_ready_command
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "reviewer" ], teams: [ "backend" ])

      assert_equal :closed, enforce(github)
      assert_includes github.writes, [ :remove_reviewers, [ "reviewer" ], [ "backend" ] ]
      assert_includes github.writes.last.last, "Run `/browser-pr-verification 123`"
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

    def test_explains_once_per_commit_and_does_nothing_without_pending_requests
      github = FakeGitHub.new(comments: [ assessment_comment ], reviewers: [ "reviewer" ])
      2.times { enforce(github) }
      assert_equal 1, github.writes.count { |write| write.first == :create_comment }

      idle = FakeGitHub.new(comments: [ assessment_comment ])
      assert_equal :closed, enforce(idle)
      assert_empty idle.writes
    end

    private

    def enforce(github) = Gate.new(github: github, log: StringIO.new).enforce(123)
  end
end
