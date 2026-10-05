module BrowserReviewGate
  # Removes reviewer requests from a PR whose browser-visible changes have not been verified yet.
  # GitHub cannot refuse a review request, so the request is taken back right after it is made.
  class Gate
    def initialize(github:, config: Config.new, log: $stdout)
      @github = github
      @config = config
      @log = log
    end

    # Returns :open when review may proceed and :closed when reviewer requests were taken back.
    def enforce(number)
      pull_request = @github.pull_request(number)
      comments = @github.comments(number)
      head_sha = pull_request.fetch("head").fetch("sha")
      assessment = Assessment.latest(comments)
      assessment = nil unless assessment&.for?(head_sha)

      return open("Browser verification is not needed.") if assessment && !assessment.required?
      return open("Required browser cases are verified.") if assessment && verified?(pull_request, comments)

      take_back_requests(number, pull_request, comments, assessment, head_sha)
    end

    private

    def open(message)
      @log.puts message
      :open
    end

    def verified?(pull_request, comments)
      pull_request.fetch("labels").any? { |label| label["name"] == @config.label } && !Report.latest_passing(comments).nil?
    end

    def take_back_requests(number, pull_request, comments, assessment, head_sha)
      reviewers = pull_request.fetch("requested_reviewers", []).map { |reviewer| reviewer["login"] }
      teams = pull_request.fetch("requested_teams", []).map { |team| team["slug"] }
      if reviewers.empty? && teams.empty?
        @log.puts "There are no pending reviewer requests to take back."
        return :closed
      end

      @github.remove_reviewers(number, reviewers: reviewers, team_reviewers: teams)
      marker = "<!-- browser-review-gate:#{head_sha} -->"
      unless comments.any? { |comment| comment["body"].to_s.include?(marker) }
        outdated = !Report.latest_passing(comments).nil?
        @github.create_comment(number, "#{marker}\n#{notice(number, assessment, outdated)}")
      end
      @log.puts "Took back reviewer requests until browser verification is available."
      :closed
    end

    # `outdated` is true when a passing run exists but no longer covers the latest commits.
    def notice(number, assessment, outdated)
      if assessment
        missing = outdated ? "the published browser run does not cover the latest commits" :
                             "no successful local browser run has been published yet"
        "Review request paused. Browser testing is required for this change, and #{missing}. " \
          "Run `#{@config.command} #{number}` in your AI coding agent from the PR branch, then request review again."
      else
        "Review request paused. The browser-testing assessment for this commit is not available. " \
          "Request review again to retry it."
      end
    end
  end
end
