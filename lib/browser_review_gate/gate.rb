require "json"

module BrowserReviewGate
  # Keeps reviewer requests off a PR whose browser behavior has not been verified, and puts them back
  # once it has. GitHub cannot refuse a review request, so a premature one is taken back right after
  # it is made; the people it named are remembered in one PR comment.
  class Gate
    PAUSED = /<!--\s*browser-review-gate:paused:([A-Za-z0-9_-]+)\s*-->/

    def initialize(github:, config: Config.new, log: $stdout)
      @github = github
      @config = config
      @log = log
    end

    # Returns :open when review may proceed and :closed when it waits for a browser run.
    def enforce(number)
      pull_request = @github.pull_request(number)
      comments = @github.trusted_comments(number)
      head_sha = pull_request.fetch("head").fetch("sha")
      assessment = Assessment.latest(comments)
      assessment = nil unless assessment&.for?(head_sha)

      verdict, description = verdict(number, pull_request, comments, assessment)
      report_status(head_sha, verdict, description)
      @log.puts description
      if verdict == :open
        restore_requests(number, pull_request, comments)
      else
        take_back_requests(number, pull_request, comments, assessment)
      end
      verdict
    end

    private

    def verdict(number, pull_request, comments, assessment)
      waived_by = waiver(number, pull_request)
      return [ :open, "Browser verification waived by #{waived_by}." ] if waived_by
      return [ :closed, "The browser-testing assessment for this commit is not available." ] unless assessment
      return [ :open, "Browser verification is not needed." ] unless assessment.required?
      return [ :open, "Required browser cases are verified." ] if verified?(number, pull_request, comments, assessment)

      [ :closed, "Browser run needed: #{@config.command} #{number}" ]
    end

    def labelled?(pull_request, label)
      pull_request.fetch("labels").any? { |entry| entry["name"] == label }
    end

    # Only cases tested on a commit of this PR count: a report about other code proves nothing here.
    def verified?(number, pull_request, comments, assessment)
      labelled?(pull_request, @config.label) &&
        assessment.covered_by?(Report.latest(comments, config: @config), commits: @github.pull_request_commits(number),
          reuse_passing: @config.scenarios["reuse_passing"])
    end

    # A waiver counts only from someone other than the author, unless the project allows otherwise.
    def waiver(number, pull_request)
      return unless labelled?(pull_request, @config.waiver_label)

      actor = @github.label_actor(number, @config.waiver_label)
      actor if actor && (@config.waiver_by_author || actor != pull_request.dig("user", "login"))
    end

    # A workflow installed before statuses were added has no permission to write them.
    def report_status(sha, verdict, description)
      @github.set_status(sha, state: verdict == :open ? "success" : "pending", description: description,
        context: @config.status_context)
    rescue Error => error
      @log.puts "Commit status was not updated: #{error.message.lines.first.to_s.strip}"
    end

    def take_back_requests(number, pull_request, comments, assessment)
      reviewers = pull_request.fetch("requested_reviewers", []).map { |reviewer| reviewer["login"] }
      teams = pull_request.fetch("requested_teams", []).map { |team| team["slug"] }
      return @log.puts("There are no pending reviewer requests to take back.") if reviewers.empty? && teams.empty?

      @github.remove_reviewers(number, reviewers: reviewers, team_reviewers: teams)
      waiting = paused(comments)
      waiting = { "reviewers" => waiting["reviewers"] | reviewers, "teams" => waiting["teams"] | teams }
      write_notice(number, comments, "#{author(pull_request)}#{notice(number, assessment, comments)}\n\n#{names(waiting)} will be " \
        "asked again automatically once the run is published.", waiting)
      @log.puts "Took back reviewer requests until browser verification is available."
    end

    # Asks the people whose requests were taken back, now that review may proceed. Someone who
    # reviewed the latest commit while the request was paused is not asked again.
    def restore_requests(number, pull_request, comments)
      waiting = paused(comments)
      waiting["reviewers"] -= [ pull_request.dig("user", "login") ]
      return if waiting.values.all?(&:empty?)

      reviewed = reviewed_head(number, pull_request) & waiting["reviewers"]
      asked = { "reviewers" => waiting["reviewers"] - reviewed, "teams" => waiting["teams"] }
      unless asked.values.all?(&:empty?)
        @github.request_reviewers(number, reviewers: asked["reviewers"], team_reviewers: asked["teams"])
      end
      write_notice(number, comments, "#{author(pull_request)}#{restored_notice(asked, reviewed)}", "reviewers" => [], "teams" => [])
      @log.puts restored_notice(asked, reviewed)
    rescue Error => error
      @log.puts "Review was not requested again: #{error.message.lines.first.to_s.strip}"
    end

    # People whose last review approved or asked for changes on the head commit.
    def reviewed_head(number, pull_request)
      head_sha = pull_request.fetch("head").fetch("sha")
      last = @github.reviews(number).group_by { |review| review.dig("user", "login") }.transform_values(&:last)
      last.select { |_login, review| review["commit_id"] == head_sha && %w[APPROVED CHANGES_REQUESTED].include?(review["state"]) }.keys
    end

    def restored_notice(asked, reviewed)
      parts = []
      parts << "Review requested again from #{names(asked)}: browser verification no longer holds it back." unless asked.values.all?(&:empty?)
      parts << "#{reviewed.map { |name| Markdown.escape(name) }.join(", ")} already reviewed the latest commit, so " \
        "#{reviewed.one? ? "was" : "were"} not asked again." if reviewed.any?
      parts.join(" ")
    end

    def notice_comment(comments)
      comments.reverse.find { |comment| comment.dig("user", "login") == Assessment::AUTHOR && comment["body"].to_s.match?(PAUSED) }
    end

    # The people whose requests were taken back and not yet restored.
    def paused(comments)
      comment = notice_comment(comments)
      data = comment ? JSON.parse(Marker.decode(comment["body"].match(PAUSED)[1])) : {}
      { "reviewers" => Array(data["reviewers"]), "teams" => Array(data["teams"]) }
    rescue ArgumentError, JSON::ParserError
      { "reviewers" => [], "teams" => [] }
    end

    def write_notice(number, comments, text, waiting)
      body = "#{text}\n\n<!-- browser-review-gate:paused:#{Marker.encode(JSON.generate(waiting))} -->"
      comment = notice_comment(comments)
      if comment.nil?
        @github.create_comment(number, body)
      elsif comment["body"] != body
        @github.update_comment(comment.fetch("id"), body)
      end
    end

    def author(pull_request) = Markdown.mention(pull_request.dig("user", "login"))

    def names(waiting)
      (waiting["reviewers"] + waiting["teams"]).map { |name| Markdown.escape(name) }.join(", ")
    end

    def notice(number, assessment, comments)
      return "Review request paused. The browser-testing assessment for this commit is not available. Request review again to retry it." unless assessment

      report = Report.latest(comments, config: @config)
      missing = report&.passed? && !assessment.covered_by?(report, commits: @github.pull_request_commits(number)) ? "the published browser run does not cover the latest commits" :
                           "no successful local browser run has been published yet"
      "Review request paused. Browser testing is required for this change, and #{missing}. " \
        "Run `#{@config.command} #{number}` in your AI coding agent from the PR branch."
    end
  end
end
