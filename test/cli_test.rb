require "test_helper"

module BrowserReviewGate
  class CLITest < Minitest::Test
    include TestData

    def test_ci_skips_ungated_prs
      github = FakeGitHub.new(author: "dependabot[bot]", reviewers: [ "reviewer" ])

      assert_equal 0, run_ci(github, FakeModel.new(answer))
      assert_empty github.writes
    end

    def test_ci_assesses_then_takes_back_a_premature_request
      github = FakeGitHub.new(reviewers: [ "reviewer" ])

      assert_equal 0, run_ci(github, FakeModel.new(answer))
      assert_equal [ :create_comment, :remove_reviewers, :create_comment ], github.writes.map(&:first)
    end

    def test_ci_keeps_review_closed_and_fails_when_the_assessment_fails
      github = FakeGitHub.new(reviewers: [ "reviewer" ])
      out = StringIO.new

      assert_equal 1, run_ci(github, FakeModel.new("garbage"), out)
      assert_includes github.writes.map(&:first), :remove_reviewers
      assert_includes out.string, "::error title=Browser verification assessment failed::"
    end

    def test_unknown_commands_print_usage
      err = StringIO.new
      assert_equal 1, CLI.new([ "frobnicate" ], stderr: err).run
      assert_includes err.string, "Usage: browser-review-gate"
    end

    private

    def run_ci(github, model, out = StringIO.new)
      CLI.new([ "ci", "123" ], stdout: out, stderr: out, github: github, config: Config.new, model: model).run
    end
  end
end
