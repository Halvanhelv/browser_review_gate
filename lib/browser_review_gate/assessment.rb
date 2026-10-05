require "json"

module BrowserReviewGate
  # The decision on whether a PR needs a browser run, and the scenarios that run must exercise. Kept in
  # one PR comment that the gate and the report publisher read back.
  class Assessment
    MARKER = /<!--\s*browser-verification-assessment:([A-Za-z0-9_-]+)\s*-->/
    # The gate workflow writes the comment with GITHUB_TOKEN; a marker from anyone else is ignored.
    AUTHOR = "github-actions[bot]"
    DECISIONS = %w[required not-required].freeze
    SHA_PATTERN = /\A\h{40}\z/
    MAX_REASON = 300
    MAX_SCENARIOS = 12
    MAX_NAME = 200

    attr_reader :assessed_sha, :decision, :reason, :scenarios, :report_seen, :errors

    # Builds an assessment from the model's JSON answer, which is untrusted. `report_seen` is the
    # fingerprint of the report the model was shown, so the same report is not judged twice.
    def self.parse(text, assessed_sha:, report_seen: nil)
      data = JSON.parse(text.to_s)
      data = {} unless data.is_a?(Hash)
      assessment = new(data.slice("decision", "reason", "scenarios").merge("assessed_sha" => assessed_sha, "report_seen" => report_seen))
      assessment.errors << "a required browser run needs at least one scenario" if assessment.required? && assessment.scenarios.empty?
      assessment
    rescue JSON::ParserError
      new({})
    end

    def self.not_required(reason, assessed_sha:)
      new("assessed_sha" => assessed_sha, "decision" => "not-required", "reason" => reason)
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
      # Comments written before scenarios existed carry the model's own verdict on coverage instead.
      @covered_by_report = data["covered_by_report"] == true
      @report_seen = data["report_seen"].is_a?(String) ? data["report_seen"] : nil
      @errors = []
      @scenarios = required? ? read_scenarios(data["scenarios"]) : []
      validate
    end

    def valid? = errors.empty?
    def required? = decision == "required"
    def for?(sha) = assessed_sha == sha

    # The scenarios no passing case of the report exercises yet.
    def outstanding(report)
      passed = report ? report.passed_ids : []
      scenarios.reject { |scenario| passed.include?(scenario["id"]) }
    end

    # A passing report covers the change when it has a passing case for every scenario.
    def covered_by?(report)
      return false unless required? && report&.passed?
      return @covered_by_report || report.tested_sha == assessed_sha if scenarios.empty?

      outstanding(report).empty?
    end

    # Whether this decision already accounts for the report, so the model need not be asked again.
    def settles?(report)
      !required? || report.nil? || scenarios.empty? || outstanding(report).empty? || report_seen == report.fingerprint
    end

    def to_h
      { "assessed_sha" => assessed_sha, "decision" => decision, "reason" => reason, "scenarios" => scenarios,
        "report_seen" => report_seen, "covered_by_report" => required? && @covered_by_report }
    end

    # `verified` is true when a passing report covers the browser behavior of this commit.
    # `command` is what the author runs in an AI coding agent, e.g. "/browser-pr-verification 42".
    # `author` is who gets mentioned, and only when the comment asks them to do something: one login
    # or several. `report` is the published run, used to tick the scenarios it already passed.
    def markdown(verified:, command:, author: nil, report: nil)
      payload = Marker.encode(JSON.generate(to_h))
      [ "## Browser verification", "", summary(verified, command, author, report), "",
        "Assessed commit `#{assessed_sha}`.", "", "<!-- browser-verification-assessment:#{payload} -->" ].join("\n")
    end

    private

    def summary(verified, command, author, report)
      why = Markdown.escape(reason)
      if !required?
        "Browser testing is not needed for this change: #{why} Human review can be requested."
      elsif verified
        "Browser testing is required for this change, and the published browser report covers it: #{why} " \
          "Human review can be requested."
      else
        [ "#{Markdown.mention(author)}Browser testing is needed before requesting human review. #{why}", "",
          *checklist(report),
          "To be able to request a reviewer, run this command in your AI coding agent from the PR branch:", "",
          "```", command, "```" ].join("\n")
      end
    end

    def checklist(report)
      return [] if scenarios.empty?

      left = outstanding(report)
      lines = scenarios.map { |scenario| "- [#{left.include?(scenario) ? " " : "x"}] `#{scenario["id"]}` #{Markdown.escape(scenario["name"])}" }
      [ "Scenarios the run must pass:", "", *lines, "" ]
    end

    # Scenario ids become report case ids, so they follow the same pattern.
    def read_scenarios(value)
      return [] if value.nil?

      unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(Hash) && entry["name"].is_a?(String) }
        errors << "scenarios must be a list of entries with an id and a name"
        return []
      end

      scenarios = value.map { |entry| { "id" => entry["id"], "name" => entry["name"].split.join(" ")[0, MAX_NAME] } }
      ids = scenarios.map { |scenario| scenario["id"] }
      errors << "scenarios must have at most #{MAX_SCENARIOS} entries" if scenarios.size > MAX_SCENARIOS
      errors << "scenario ids must use letters, numbers, dots, underscores, or hyphens" unless ids.all? { |id| id.is_a?(String) && Report::CASE_ID_PATTERN.match?(id) }
      errors << "scenario ids must be unique" unless ids.uniq.size == ids.size
      errors << "scenario names must not be empty" if scenarios.any? { |scenario| scenario["name"].empty? }
      scenarios
    end

    def validate
      errors << "assessed_sha must be a full commit SHA" unless assessed_sha.is_a?(String) && SHA_PATTERN.match?(assessed_sha)
      errors << "decision must be required or not-required" unless DECISIONS.include?(decision)
      errors << "reason must be a non-empty string" if reason.to_s.empty?
    end
  end
end
