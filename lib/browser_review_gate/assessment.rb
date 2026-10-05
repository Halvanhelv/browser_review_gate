require "json"

module BrowserReviewGate
  # The decision on whether a PR needs a browser run, kept in one PR comment that the gate and the
  # report publisher read back.
  class Assessment
    MARKER = /<!--\s*browser-verification-assessment:([A-Za-z0-9_-]+)\s*-->/
    # The gate workflow writes the comment with GITHUB_TOKEN; a marker from anyone else is ignored.
    AUTHOR = "github-actions[bot]"
    DECISIONS = %w[required not-required].freeze
    SHA_PATTERN = /\A\h{40}\z/
    MAX_REASON = 300

    attr_reader :assessed_sha, :decision, :reason, :errors

    # Builds an assessment from the model's JSON answer, which is untrusted.
    def self.parse(text, assessed_sha:)
      data = JSON.parse(text.to_s)
      data = {} unless data.is_a?(Hash)
      new(data.slice("decision", "reason", "covered_by_report").merge("assessed_sha" => assessed_sha))
    rescue JSON::ParserError
      new({})
    end

    def self.not_required(reason, assessed_sha:)
      new("assessed_sha" => assessed_sha, "decision" => "not-required", "reason" => reason, "covered_by_report" => false)
    end

    # The newest valid assessment the gate workflow wrote on the PR, or nil.
    def self.latest(comments)
      comment = latest_comment(comments)
      return unless comment

      assessment = new(JSON.parse(Marker.decode(comment["body"].match(MARKER)[1])))
      assessment if assessment.valid?
    rescue ArgumentError, JSON::ParserError
      nil
    end

    def self.latest_comment(comments)
      comments.reverse.find do |comment|
        comment.dig("user", "login") == AUTHOR && comment["body"].to_s.match?(MARKER)
      end
    end

    def initialize(data)
      data = {} unless data.is_a?(Hash)
      @assessed_sha = data["assessed_sha"]
      @decision = data["decision"]
      @reason = data["reason"].is_a?(String) ? data["reason"].split.join(" ")[0, MAX_REASON] : nil
      @covered_by_report = data["covered_by_report"]
      @errors = []
      validate
    end

    def valid? = errors.empty?
    def required? = decision == "required"
    def covered_by_report? = required? && @covered_by_report == true
    def for?(sha) = assessed_sha == sha

    def to_h
      { "assessed_sha" => assessed_sha, "decision" => decision, "reason" => reason,
        "covered_by_report" => covered_by_report? }
    end

    # `verified` is true when a passing report covers the browser behavior of this commit.
    # `command` is what the author runs in an AI coding agent, e.g. "/browser-pr-verification 42".
    # `author` is who gets mentioned, and only when the comment asks them to do something: one login
    # or several.
    def markdown(verified:, command:, author: nil)
      payload = Marker.encode(JSON.generate(to_h))
      [ "## Browser verification", "", summary(verified, command, author), "",
        "Assessed commit `#{assessed_sha}`.", "", "<!-- browser-verification-assessment:#{payload} -->" ].join("\n")
    end

    private

    def summary(verified, command, author)
      why = Markdown.escape(reason)
      if !required?
        "Browser testing is not needed for this change: #{why} Human review can be requested."
      elsif verified
        "Browser testing is required for this change, and the published browser report covers it: #{why} " \
          "Human review can be requested."
      else
        [ "#{Markdown.mention(author)}Browser testing is needed before requesting human review. #{why}", "",
          "To be able to request a reviewer, run this command in your AI coding agent from the PR branch:", "",
          "```", command, "```" ].join("\n")
      end
    end

    def validate
      errors << "assessed_sha must be a full commit SHA" unless assessed_sha.is_a?(String) && SHA_PATTERN.match?(assessed_sha)
      errors << "decision must be required or not-required" unless DECISIONS.include?(decision)
      errors << "reason must be a non-empty string" if reason.to_s.empty?
      errors << "covered_by_report must be true or false" unless [ true, false ].include?(@covered_by_report)
    end
  end
end
