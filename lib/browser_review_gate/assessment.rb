require "json"

module BrowserReviewGate
  # The decision on whether a PR needs a browser run, and the scenarios that run must exercise. Kept in
  # one PR comment that the gate and the report publisher read back.
  #
  # Scenarios come from two places: the model proposes them from the diff, and the project settings add
  # mandatory ones (`scenarios.mandatory`). Mandatory scenarios are added by this code after the model
  # answered, so neither the model nor the PR can leave them out.
  class Assessment
    MARKER = /<!--\s*browser-verification-assessment:([A-Za-z0-9_-]+)\s*-->/
    # The gate workflow writes the comment with GITHUB_TOKEN; a marker from anyone else is ignored.
    AUTHOR = "github-actions[bot]"
    DECISIONS = %w[required not-required].freeze
    PRIORITIES = %w[critical normal].freeze
    SHA_PATTERN = /\A\h{40}\z/
    MAX_REASON = 300
    MAX_NAME = 200
    MAX_WHY = 200
    CATEGORY_PATTERN = /\A[a-z][a-z0-9-]{0,31}\z/
    STATUS_MARKS = { "passed" => "x", "failed" => " ", "skipped" => " ", "blocked" => " ", "missing" => " ", "stale" => " " }.freeze

    LOCAL_REASON = "This change can affect the browser, and the author's agent decides what to run."

    attr_reader :assessed_sha, :decision, :reason, :scenarios, :report_seen, :usage, :errors

    # Builds an assessment from the model's JSON answer, which is untrusted. `report_seen` is the
    # fingerprint of the report the model was shown, so the same report is not judged twice.
    # `mandatory` are the scenarios the settings require for this change.
    def self.parse(text, assessed_sha:, report_seen: nil, mandatory: [], max_count: 12, usage: nil)
      data = JSON.parse(text.to_s)
      data = {} unless data.is_a?(Hash)
      proposed = data["scenarios"]
      if proposed.is_a?(Array) && proposed.size > max_count
        return new({ "assessed_sha" => assessed_sha }).tap { |assessment| assessment.errors << "scenarios must have at most #{max_count} entries" }
      end

      if data["decision"] == "required" && proposed.is_a?(Array)
        taken = proposed.map { |entry| entry.is_a?(Hash) ? entry["id"] : nil }
        data["scenarios"] = proposed + mandatory.reject { |scenario| taken.include?(scenario["id"]) }
      end
      assessment = new(data.slice("decision", "reason", "scenarios").merge("assessed_sha" => assessed_sha, "report_seen" => report_seen, "usage" => usage))
      assessment.errors << "a required browser run needs at least one scenario" if assessment.required? && assessment.scenarios.empty?
      assessment
    rescue JSON::ParserError
      new({})
    end

    def self.not_required(reason, assessed_sha:)
      new("assessed_sha" => assessed_sha, "decision" => "not-required", "reason" => reason)
    end

    # `assessment: local`: no model. A run is owed whenever the change touches more than ignored paths;
    # the author's agent picks the scenarios, and the settings' mandatory ones are listed here.
    def self.local(assessed_sha:, mandatory:)
      new("assessed_sha" => assessed_sha, "decision" => "required", "reason" => LOCAL_REASON, "scenarios" => mandatory, "mode" => "local")
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
      @report_seen = data["report_seen"].is_a?(String) ? data["report_seen"] : nil
      @usage = read_usage(data["usage"])
      @mode = data["mode"] == "local" ? "local" : "ci"
      @errors = []
      @scenarios = required? ? read_scenarios(data["scenarios"]) : []
      validate
    end

    def valid? = errors.empty?
    def required? = decision == "required"
    def for?(sha) = assessed_sha == sha
    def local? = @mode == "local"

    # The scenarios no counting case of the report exercises yet. With `commits`, only cases tested on
    # those commits count; with `reuse_passing` false, only cases tested on the assessed commit.
    def outstanding(report, commits: nil, reuse_passing: true)
      allowed = reuse_passing ? commits : [ assessed_sha ]
      passed = report ? report.passed_ids(commits: allowed) : []
      scenarios.reject { |scenario| passed.include?(scenario["id"]) }
    end

    # A report covers the change when it is complete, nothing failed (unless failures do not block),
    # and every scenario has a counting case.
    #
    # In local mode nobody but the agent names the scenarios, so the report must also be fresh: run on
    # this commit, or on an earlier one with only ignored paths changed since (`fresh`, worked out by
    # the caller from the PR). It must pass a case of its own or say why no run is needed.
    def covered_by?(report, commits: nil, reuse_passing: true, fresh: true)
      return false unless required? && report&.passed?
      return false unless outstanding(report, commits: commits, reuse_passing: reuse_passing).empty?
      return true unless local?

      fresh && (report.not_required? || report.passed_ids(commits: commits).any?)
    end

    # Whether this decision already accounts for the report, so the model need not be asked again.
    def settles?(report)
      !required? || report.nil? || outstanding(report).empty? || report_seen == report.fingerprint
    end

    def to_h
      { "assessed_sha" => assessed_sha, "decision" => decision, "reason" => reason, "scenarios" => scenarios,
        "report_seen" => report_seen, "usage" => usage, "mode" => local? ? "local" : nil }.compact
    end

    # `verified` is true when a report covers the browser behavior of this commit. `command` is what the
    # author runs in an AI coding agent. `author` is who gets mentioned, and only when the comment asks
    # them to do something. `report` and `commits` give each scenario its status.
    def markdown(verified:, command:, author: nil, report: nil, commits: nil)
      payload = Marker.encode(JSON.generate(to_h))
      [ Markdown::SIGNATURE, "", "## Browser verification", "", summary(verified, command, author, report, commits), "",
        "Assessed commit `#{assessed_sha}`.", "", "<!-- browser-verification-assessment:#{payload} -->" ].join("\n")
    end

    private

    def summary(verified, command, author, report, commits)
      why = Markdown.escape(reason)
      if !required?
        "Browser testing is not needed for this change: #{why} Human review can be requested."
      elsif verified
        [ "**Human review can proceed.** Browser testing is required for this change, and the published browser report covers it: #{why}",
          "", *checklist(report, commits) ].join("\n").rstrip
      else
        [ "#{Markdown.mention(author)}**Human review is on hold.** Browser testing is needed before requesting human review. #{why}", "",
          *checklist(report, commits),
          "To be able to request a reviewer, run this command in your AI coding agent from the PR branch:", "",
          "```", command, "```" ].join("\n")
      end
    end

    def checklist(report, commits)
      return local_checklist(report) if local? && scenarios.empty?

      lines = scenarios.map do |scenario|
        status = report ? report.status_of(scenario["id"], commits: commits) : "missing"
        flags = [ scenario["priority"] == "critical" ? "critical" : nil, scenario["category"] ].compact.join(", ")
        why = scenario["why"] ? " — #{Markdown.escape(scenario["why"])}" : ""
        "- [#{STATUS_MARKS.fetch(status)}] **#{status}** `#{scenario["id"]}` #{Markdown.escape(scenario["name"])}" \
          "#{flags.empty? ? "" : " (#{Markdown.escape(flags)})"}#{why}"
      end
      [ "Scenarios the run must pass:", "", *lines, "" ]
    end

    def local_checklist(report)
      done = report&.not_required? ? "the author's agent judged that no run is needed" :
             report ? "#{report.passed_ids.size} passing cases published" : "no run published yet"
      [ "The author's AI agent chooses the scenarios from the diff and the project rules (#{done}).", "" ]
    end

    # Scenario ids become report case ids, so they follow the same pattern.
    def read_scenarios(value)
      return [] if value.nil?

      unless value.is_a?(Array) && value.all? { |entry| entry.is_a?(Hash) && entry["name"].is_a?(String) }
        errors << "scenarios must be a list of entries with an id and a name"
        return []
      end

      scenarios = value.map { |entry| read_scenario(entry) }
      ids = scenarios.map { |scenario| scenario["id"] }
      errors << "scenarios must have at most #{Config::MAX_SCENARIOS + Config::MAX_MATRIX_CASES} entries" if scenarios.size > Config::MAX_SCENARIOS + Config::MAX_MATRIX_CASES
      errors << "scenario ids must use letters, numbers, dots, underscores, or hyphens" unless ids.all? { |id| id.is_a?(String) && Report::CASE_ID_PATTERN.match?(id) }
      errors << "scenario ids must be unique" unless ids.uniq.size == ids.size
      errors << "scenario names must not be empty" if scenarios.any? { |scenario| scenario["name"].empty? }
      errors << "scenario priority must be critical or normal" unless scenarios.all? { |scenario| PRIORITIES.include?(scenario["priority"]) }
      errors << "scenario category must be a short lowercase word" unless scenarios.all? { |scenario| scenario["category"].nil? || CATEGORY_PATTERN.match?(scenario["category"]) }
      scenarios
    end

    def read_scenario(entry)
      scenario = { "id" => entry["id"], "name" => entry["name"].split.join(" ")[0, MAX_NAME],
                   "priority" => entry["priority"] || "normal",
                   "category" => entry["category"].is_a?(String) && !entry["category"].empty? ? entry["category"].downcase : nil,
                   "why" => entry["why"].is_a?(String) && !entry["why"].strip.empty? ? entry["why"].split.join(" ")[0, MAX_WHY] : nil }
      scenario["matrix"] = entry["matrix"] if entry["matrix"].is_a?(Hash)
      scenario.compact
    end

    # Token counts and cost as the provider reported them; nothing is estimated here.
    def read_usage(value)
      return unless value.is_a?(Hash)

      usage = value.slice("provider", "model", "input_tokens", "output_tokens", "cost_usd").select do |key, entry|
        %w[provider model].include?(key) ? entry.is_a?(String) && entry.length <= 80 : entry.is_a?(Numeric) && entry >= 0
      end
      usage.empty? ? nil : usage
    end

    def validate
      errors << "assessed_sha must be a full commit SHA" unless assessed_sha.is_a?(String) && SHA_PATTERN.match?(assessed_sha)
      errors << "decision must be required or not-required" unless DECISIONS.include?(decision)
      errors << "reason must be a non-empty string" if reason.to_s.empty?
    end
  end
end
