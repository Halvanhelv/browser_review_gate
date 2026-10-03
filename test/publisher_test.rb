require "test_helper"

module BrowserReviewGate
  class PublisherTest < Minitest::Test
    include TestData

    def test_publishes_the_report_before_adding_the_label
      github = FakeGitHub.new(comments: [ assessment_comment ])

      assert publisher(github, report_path: report_file).publish
      assert_equal [ :create_comment, :add_label ], github.writes.map(&:first)
      assert_includes github.writes.fetch(0).last, "Verified by **AI browser agent \\(run by dev-user\\)**"
    end

    def test_an_incomplete_or_failing_run_is_published_but_removes_the_label
      github = FakeGitHub.new(comments: [ assessment_comment ], labels: [ "browser-verified" ])

      refute publisher(github, report_path: report_file("coverage_complete" => false)).publish
      assert_equal [ :remove_label, :create_comment ], github.writes.map(&:first)
      assert_includes github.writes.last.last, "Not verified"
    end

    def test_new_cases_merge_with_earlier_ones_in_the_authors_own_comment
      github = FakeGitHub.new(comments: [ assessment_comment, report_comment({ "tested_sha" => OLD }, id: 9) ])

      assert publisher(github, report_path: report_file("cases" => [ { "id" => "BROWSER-2", "name" => "Save", "result" => "pass" } ])).publish
      kind, id, body = github.writes.fetch(0)
      assert_equal [ :update_comment, 9 ], [ kind, id ]
      cases = Report.data_from(body).fetch("cases")
      assert_equal %w[BROWSER-1 BROWSER-2], cases.map { |test_case| test_case["id"] }
      assert_equal OLD, cases.fetch(0).fetch("tested_sha")
    end

    def test_scenarios_excluded_by_the_author_are_shown_in_the_report
      github = FakeGitHub.new(comments: [ assessment_comment ])
      path = report_file("excluded" => [ { "name" => "Sign-in through a provider", "reason" => "Needs a real account." } ])

      assert publisher(github, report_path: path).publish
      assert_includes github.writes.fetch(0).last, "Sign-in through a provider"
    end

    def test_a_run_saved_before_the_pr_existed_is_published_for_the_branch_pr_and_forgotten
      github = FakeGitHub.new
      shell = FakeShell.new
      publisher(github, report_path: report_file, shell: shell).save
      assert File.exist?(shell.saved_path)

      assert Publisher.new(github: github, shell: shell).publish
      assert_equal [ :create_comment, :add_label ], github.writes.map(&:first)
      refute File.exist?(shell.saved_path)
    end

    def test_refuses_before_writing
      { "dirty worktree" => [ FakeGitHub.new, FakeShell.new(status: " M app/x.rb\n?? notes.txt\n"), report_file, /notes\.txt/ ],
        "another commit" => [ FakeGitHub.new, FakeShell.new, report_file("tested_sha" => OLD), /tested_sha/ ],
        "stale checkout" => [ FakeGitHub.new(head: OLD), FakeShell.new, report_file, /does not match the PR head/ ],
        "not required" => [ FakeGitHub.new(comments: [ assessment_comment(decision: "not-required") ]), FakeShell.new, report_file, /not marked as requiring/ ],
        "nothing saved" => [ FakeGitHub.new, FakeShell.new, nil, /No saved browser verification/ ] }.each do |name, (github, shell, path, message)|
        error = assert_raises(Error, name) { publisher(github, report_path: path, shell: shell).publish }
        assert_match message, error.message, name
        assert_empty github.writes, name
      end
    end

    def test_a_branch_without_a_pr_cannot_publish
      github = FakeGitHub.new
      github.branch_pr = nil

      error = assert_raises(Error) { Publisher.new(github: github, report_path: report_file, shell: FakeShell.new).publish }
      assert_match(/no pull request yet/, error.message)
    end

    private

    def publisher(github, report_path:, shell: FakeShell.new)
      Publisher.new(github: github, number: 123, report_path: report_path, shell: shell)
    end
  end
end
