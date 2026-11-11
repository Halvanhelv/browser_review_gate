require "digest"
require "json"
require "time"

module BrowserReviewGate
  # The browser cases an agent ran, with their outcomes and evidence. Published as one PR comment.
  #
  # Everything in a report is the agent's account except the file digests, which the publisher
  # computed from files it read. The report is validated strictly: an unknown key, a malformed value
  # or a missing field makes it invalid, and an invalid report counts for nothing.
  class Report
    MARKER = /<!--\s*browser-verification-report:([A-Za-z0-9_-]+)\s*-->/
    SCHEMA_VERSION = 2
    FULL_SHA = /\A\h{40}\z/
    CASE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
    RESULTS = %w[pass fail skipped blocked].freeze
    CAPABILITIES = %w[screenshots trace console network].freeze
    URL_PATTERN = %r{\A(?:https?://|/)\S*\z}
    TOP_KEYS = %w[schema_version tested_sha verified_by environment tool started_at finished_at coverage_complete
                  cases excluded runs failed_runs not_required].freeze
    CASE_KEYS = %w[id name result url details reason evidence tested_sha verified_by environment tool].freeze
    EVIDENCE_KEYS = %w[files console_errors network_errors links trace_check].freeze
    FILE_KEYS = %w[kind name media_type bytes sha256].freeze

    attr_reader :errors

    def self.latest_comment(comments)
      comments.reverse.find { |comment| comment["body"].to_s.match?(MARKER) }
    end

    # The report data embedded in a comment body; raises Error when the marker is damaged.
    def self.data_from(body)
      JSON.parse(Marker.decode(body.to_s.match(MARKER)[1]))
    rescue ArgumentError, JSON::ParserError
      raise Error, "Existing browser verification report has a malformed data marker"
    end

    # The newest report on the PR when it is well formed, or nil.
    def self.latest(comments, config: Config.new)
      comment = latest_comment(comments)
      report = comment && new(data_from(comment["body"]), config: config)
      report if report&.valid?
    rescue Error
      nil
    end

    # Later results replace earlier ones case by case; cases that were not run again are kept. The
    # merged report counts the runs published on the PR and how many of them had a failing case.
    def self.merge(previous_data, latest_data, config: Config.new)
      previous = new(previous_data, config: config)
      latest = new(latest_data, config: config)
      return latest unless latest.valid?

      combined = previous.valid? ? previous.cases.to_h { |test_case| [ test_case["id"], test_case ] } : {}
      latest.cases.each { |test_case| combined[test_case["id"]] = test_case }
      failed = latest.cases.any? { |test_case| test_case["result"] == "fail" } ? 1 : 0
      new(latest.to_h.merge("cases" => combined.values, "runs" => previous.runs + 1, "failed_runs" => previous.failed_runs + failed), config: config)
    end

    def initialize(data, config: Config.new)
      @config = config
      @errors = []
      @data = normalize(data.is_a?(Hash) ? data : {})
      attach_defaults_to_cases
      validate
    end

    def valid? = errors.empty?
    def tested_sha = @data["tested_sha"]
    def verified_by = @data["verified_by"]
    def environment = @data["environment"]
    def tool = @data["tool"].is_a?(Hash) ? @data["tool"] : {}
    def cases = @data["cases"].is_a?(Array) ? @data["cases"] : []
    def excluded = @data["excluded"].is_a?(Array) ? @data["excluded"] : []
    def runs = @data["runs"].is_a?(Integer) ? @data["runs"] : 0
    def failed_runs = @data["failed_runs"].is_a?(Integer) ? @data["failed_runs"] : 0
    def coverage_complete? = @data["coverage_complete"] == true

    # With `assessment: local`, the author's agent may judge that the change needs no browser run. The
    # reason is shown in the PR for the reviewer to weigh.
    def not_required_reason = @data["not_required"].is_a?(Hash) ? @data["not_required"]["reason"] : nil
    def not_required? = !not_required_reason.nil?
    def to_h = JSON.parse(JSON.generate(@data))

    # Seconds the run took, when the agent gave both times.
    def duration
      return unless @data["started_at"] && @data["finished_at"]

      Time.iso8601(@data["finished_at"]) - Time.iso8601(@data["started_at"])
    end

    # Ids of the cases that count as passed under the project's policy, limited to cases tested on
    # `commits` when that list is given (the commits of the PR: a case from elsewhere proves nothing).
    def passed_ids(commits: nil)
      cases.select { |test_case| counts?(test_case) && (commits.nil? || commits.include?(test_case["tested_sha"])) }
        .map { |test_case| test_case["id"] }
    end

    # passed, failed, skipped, blocked, or missing when no case has the id. A case that says pass but
    # breaks a policy (console errors, missing evidence) is failed.
    def status_of(id, commits: nil)
      test_case = cases.find { |entry| entry["id"] == id }
      return "missing" unless test_case
      return "stale" if commits && !commits.include?(test_case["tested_sha"])
      return "passed" if counts?(test_case)

      test_case["result"] == "pass" ? "failed" : { "fail" => "failed" }.fetch(test_case["result"], test_case["result"])
    end

    # Why a case that says pass does not count, or nil.
    def policy_problem(test_case)
      evidence = test_case["evidence"].is_a?(Hash) ? test_case["evidence"] : {}
      if @config.verification["fail_on_console_errors"] && Array(evidence["console_errors"]).any?
        return "console errors were reported"
      end
      if @config.verification["fail_on_network_errors"] && Array(evidence["network_errors"]).any?
        return "failed network requests were reported"
      end

      missing_evidence(test_case, evidence) || trace_problem(evidence)
    end

    def failed? = cases.any? { |test_case| status_of(test_case["id"]) == "failed" }

    # Complete, and nothing failed when failures block review.
    def passed?
      valid? && (coverage_complete? || not_required?) && (!@config.gate["block_on_failure"] || !failed?)
    end

    # Changes whenever a case is added, re-run or changes its outcome.
    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate(cases.map { |test_case| test_case.values_at("id", "result", "tested_sha") }))[0, 16]
    end

    # What a newly submitted run must say beyond the schema: where each case ran and what was seen,
    # and the evidence the project requires.
    def submission_errors
      cases.each_with_index.flat_map do |test_case, index|
        position = index + 1
        found = []
        if %w[pass fail].include?(test_case["result"])
          found << "case #{position} url must be the page that was exercised: an http(s) URL or a path starting with /" unless url?(test_case["url"])
        else
          found << "case #{position} is #{test_case["result"]} and needs a reason" unless text?(test_case["reason"], 300)
        end
        found << "case #{position} details must say what was observed" unless text?(test_case["details"], 500)
        evidence = test_case["evidence"].is_a?(Hash) ? test_case["evidence"] : {}
        problem = test_case["result"] == "pass" ? (missing_evidence(test_case, evidence) || trace_problem(evidence)) : nil
        found << "case #{position} #{problem}" if problem
        found
      end
    end

    def markdown(scenarios: nil, commits: nil)
      return "Browser verification report is invalid: #{errors.map { |error| Markdown.escape(error) }.join("; ")}" unless valid?

      coverage = coverage_complete? ? "Complete scenario run." : "Scenario run is incomplete."
      tool_name = [ tool["name"], tool["version"] ].compact.map { |part| Markdown.escape(part) }.join(" ")
      lines = [ "## Browser verification", "",
        "Verified by **#{Markdown.escape(verified_by)}** for commit `#{tested_sha}` in the `#{environment}` environment " \
        "with #{tool_name}#{timing}. #{coverage}", "",
        *(cases.any? ? [ "| Case | Result | Page | Commit | Evidence |", "|---|---|---|---|---|" ] : []) ]
      lines.concat(cases.map { |test_case| markdown_case(test_case, commits) })
      lines.concat([ "", "**The author's agent judged that no browser run is needed:** #{Markdown.escape(not_required_reason)}" ]) if not_required?
      details = cases.select { |test_case| test_case["details"] || test_case["reason"] }
      lines.concat([ "", "<details><summary>What the agent observed</summary>", "" ] +
        details.map { |test_case| "- `#{test_case["id"]}`: #{Markdown.escape([ test_case["details"], test_case["reason"] ].compact.join(" "))}" } +
        [ "", "</details>" ]) if details.any?
      lines.concat([ "", "Not exercised in the browser, by the author's decision:" ] + excluded.map { |entry| markdown_excluded(entry) }) if excluded.any?
      lines.concat([ "", "Observations, pages and errors are reported by the agent. File digests were computed by the publisher " \
        "from files it read; they show the files existed, not that a browser made them." ])
      payload = Marker.encode(JSON.generate(to_h))
      lines.concat([ "", "<!-- browser-verification-report:#{payload} -->" ]).join("\n")
    end

    private

    def counts?(test_case)
      test_case["result"] == "pass" && policy_problem(test_case).nil?
    end

    # The evidence the project asks for and the tool could produce. A tool that does not declare a
    # capability is not asked for it; that gap is visible in the PR.
    def missing_evidence(test_case, evidence)
      return unless @config.gate["require_evidence"]

      capabilities = Array(tool_of(test_case)["capabilities"])
      files = Array(evidence["files"])
      kinds = { "screenshots" => "screenshot", "trace" => "trace" }
      kinds.each do |setting, kind|
        mode = @config.evidence[setting]
        wanted = mode == "always" || (mode == "on_failure" && test_case["result"] == "fail")
        next unless wanted && capabilities.include?(setting)
        return "has no #{kind} although evidence.#{setting} is #{mode}" if files.none? { |file| file["kind"] == kind }
      end
      { "console_logs" => [ "console", "console_errors" ], "network_logs" => [ "network", "network_errors" ] }.each do |setting, (capability, key)|
        next unless @config.evidence[setting] && capabilities.include?(capability)
        return "does not say whether there were #{key.tr("_", " ")} (evidence.#{key})" unless evidence.key?(key)
      end
      nil
    end

    # With provenance.trace require, a passing case counts only when its trace showed the run.
    def trace_problem(evidence)
      return unless @config.provenance["trace"] == "require"

      check = evidence["trace_check"]
      return "has no Playwright trace, which provenance.trace requires" unless check.is_a?(Hash)
      return if check["status"] == "verified"

      "trace does not show the run: #{Array(check["findings"]).first || "the check failed"}"
    end

    # A carried-over case keeps the tool of the run that produced it.
    def tool_of(test_case) = test_case["tool"].is_a?(Hash) ? test_case["tool"] : tool

    def timing
      seconds = duration
      seconds ? " in #{seconds.round} s" : ""
    end

    def normalize(value)
      case value
      when Hash then value.to_h { |key, nested| [ key.to_s, normalize(nested) ] }
      when Array then value.map { |entry| normalize(entry) }
      else value
      end
    end

    def attach_defaults_to_cases
      cases.each do |test_case|
        next unless test_case.is_a?(Hash)

        %w[tested_sha verified_by environment tool].each { |key| test_case[key] ||= @data[key] }
      end
    end

    def validate
      unknown = @data.keys - TOP_KEYS
      errors << "unknown report keys: #{unknown.join(", ")}" if unknown.any?
      errors << "schema_version must be #{SCHEMA_VERSION}" unless @data["schema_version"] == SCHEMA_VERSION
      errors << "tested_sha must be a full 40-character commit SHA" unless sha?(@data["tested_sha"])
      errors << "verified_by must be a non-empty string of at most 100 characters" unless text?(@data["verified_by"], 100)
      errors << "environment must name an environment from the settings" unless name?(@data["environment"])
      errors << "coverage_complete must be true or false" unless [ true, false ].include?(@data["coverage_complete"])
      validate_tool
      validate_times
      validate_cases
      validate_not_required if @data["cases"] != []
      validate_excluded
      %w[runs failed_runs].each do |key|
        errors << "#{key} must be a whole number" unless @data[key].nil? || (@data[key].is_a?(Integer) && @data[key] >= 0)
      end
    end

    def validate_tool
      tool_data = @data["tool"]
      return errors << "tool must say which browser tool ran the cases: {\"name\": ..., \"capabilities\": [...]}" unless tool_data.is_a?(Hash)

      unknown = tool_data.keys - %w[name version capabilities]
      errors << "unknown tool keys: #{unknown.join(", ")}" if unknown.any?
      errors << "tool name must be a non-empty string of at most 60 characters" unless text?(tool_data["name"], 60)
      errors << "tool version must be a string of at most 40 characters" unless tool_data["version"].nil? || text?(tool_data["version"], 40)
      capabilities = tool_data["capabilities"]
      return if capabilities.is_a?(Array) && (capabilities - CAPABILITIES).empty? && capabilities.uniq.size == capabilities.size

      errors << "tool capabilities must be a list drawn from #{CAPABILITIES.join(", ")}"
    end

    def validate_times
      times = %w[started_at finished_at].to_h do |key|
        [ key, Time.iso8601(@data[key].to_s) ]
      rescue ArgumentError
        errors << "#{key} must be an ISO 8601 time"
        [ key, nil ]
      end
      return unless times.values.all?

      errors << "finished_at must not be before started_at" if times["finished_at"] < times["started_at"]
    end

    def validate_not_required
      value = @data["not_required"]
      return if value.nil?
      return if value.is_a?(Hash) && value.keys == [ "reason" ] && text?(value["reason"], 300)

      errors << "not_required must be { \"reason\": \"why no browser run is needed\" }"
    end

    def validate_cases
      return validate_not_required if @data["not_required"] && @data["cases"] == []
      return errors << "cases must be a non-empty array" unless @data["cases"].is_a?(Array) && cases.any?
      return errors << "cases must have at most 60 entries" if cases.size > 60

      seen_ids = []
      cases.each_with_index do |test_case, index|
        next errors << "case #{index + 1} must be an object" unless test_case.is_a?(Hash)

        validate_case(test_case, index + 1, seen_ids)
      end
    end

    def validate_case(test_case, position, seen_ids)
      unknown = test_case.keys - CASE_KEYS
      errors << "case #{position} has unknown keys: #{unknown.join(", ")}" if unknown.any?
      id = test_case["id"]
      if !(id.is_a?(String) && CASE_ID_PATTERN.match?(id))
        errors << "case #{position} id must use letters, numbers, dots, underscores, or hyphens"
      elsif seen_ids.include?(id)
        errors << "case id #{id.inspect} appears more than once"
      else
        seen_ids << id
      end
      errors << "case #{position} name must be a non-empty string of at most 200 characters" unless text?(test_case["name"], 200)
      errors << "case #{position} result must be one of #{RESULTS.join(", ")}" unless RESULTS.include?(test_case["result"])
      errors << "case #{position} tested_sha must be a full commit SHA" unless sha?(test_case["tested_sha"])
      errors << "case #{position} verified_by must be a non-empty string of at most 100 characters" unless text?(test_case["verified_by"], 100)
      errors << "case #{position} environment must be a short lowercase name" unless name?(test_case["environment"])
      errors << "case #{position} url must be a string of at most 300 characters" unless test_case["url"].nil? || url?(test_case["url"])
      errors << "case #{position} details must be a string of at most 500 characters" unless test_case["details"].nil? || text?(test_case["details"], 500)
      errors << "case #{position} reason must be a string of at most 300 characters" unless test_case["reason"].nil? || text?(test_case["reason"], 300)
      errors << "case #{position} tool must name the browser tool" unless test_case["tool"].is_a?(Hash) && text?(test_case["tool"]["name"], 60)
      validate_evidence(test_case["evidence"], position) unless test_case["evidence"].nil?
    end

    # The published form of evidence; the submitted form is turned into this by Evidence.
    def validate_evidence(evidence, position)
      return errors << "case #{position} evidence must be an object" unless evidence.is_a?(Hash)

      unknown = evidence.keys - EVIDENCE_KEYS
      errors << "case #{position} evidence has unknown keys: #{unknown.join(", ")}" if unknown.any?
      files = evidence["files"]
      unless files.nil? || (files.is_a?(Array) && files.size <= Evidence::MAX_FILES && files.all? { |file| file?(file) })
        errors << "case #{position} evidence files are malformed"
      end
      validate_trace_check(evidence["trace_check"], position) unless evidence["trace_check"].nil?
      links = Array(evidence["links"])
      errors << "case #{position} evidence links must be https URLs" unless links.all? { |link| link.to_s.match?(%r{\Ahttps://[^\s()<>]+\z}) }
      %w[console_errors network_errors links].each do |key|
        value = evidence[key]
        next if value.nil? || (value.is_a?(Array) && value.size <= Evidence::MAX_ENTRIES && value.all? { |entry| entry.is_a?(String) && entry.length <= Evidence::MAX_ENTRY })

        errors << "case #{position} evidence #{key} must be a list of short strings"
      end
    end

    def validate_trace_check(check, position)
      valid = check.is_a?(Hash) && (check.keys - %w[status revision requests findings]).empty? &&
        %w[verified failed].include?(check["status"]) && (check["revision"].nil? || check["revision"].to_s.match?(/\A\h{7,12}\z/)) &&
        check["requests"].is_a?(Integer) && check["findings"].is_a?(Array) && check["findings"].size <= 5 &&
        check["findings"].all? { |finding| finding.is_a?(String) && finding.length <= 300 }
      errors << "case #{position} evidence trace_check is malformed" unless valid
    end

    def file?(file)
      file.is_a?(Hash) && (file.keys - FILE_KEYS).empty? && Evidence::KINDS.value?(file["kind"]) && text?(file["name"], 100) &&
        file["bytes"].is_a?(Integer) && file["sha256"].to_s.match?(/\A\h{64}\z/) && Evidence::TYPES.values.map(&:first).include?(file["media_type"])
    end

    # Scenarios the author decided not to run locally, e.g. a sign-in through an external provider.
    def validate_excluded
      return if @data["excluded"].nil?
      return errors << "excluded must be an array" unless @data["excluded"].is_a?(Array)

      excluded.each_with_index do |entry, index|
        next if entry.is_a?(Hash) && (entry.keys - %w[id name reason]).empty? && text?(entry["name"], 200) && text?(entry["reason"], 500) &&
          (entry["id"].nil? || CASE_ID_PATTERN.match?(entry["id"].to_s))

        errors << "excluded #{index + 1} needs a name and a reason"
      end
    end

    def sha?(value) = value.is_a?(String) && FULL_SHA.match?(value)
    def name?(value) = value.is_a?(String) && Config::NAME_PATTERN.match?(value)
    def text?(value, limit) = value.is_a?(String) && !value.strip.empty? && value.length <= limit
    def url?(value) = value.is_a?(String) && value.length <= 300 && URL_PATTERN.match?(value)

    def markdown_case(test_case, commits)
      status = status_of(test_case["id"], commits: commits)
      problem = test_case["result"] == "pass" && status == "failed" ? " (#{policy_problem(test_case)})" : ""
      page = test_case["url"].to_s.empty? ? "" : Markdown.escape(test_case["url"])
      "| `#{test_case["id"]}` #{Markdown.escape(test_case["name"])} | #{status.upcase}#{Markdown.escape(problem)} | #{page} | " \
        "`#{test_case["tested_sha"][0, 7]}` | #{markdown_evidence(test_case["evidence"])} |"
    end

    def markdown_evidence(evidence)
      return "none" unless evidence.is_a?(Hash)

      parts = Array(evidence["files"]).map { |file| "#{file["kind"]} `#{Markdown.escape(file["name"])}` (#{file["bytes"]} B, sha256 `#{file["sha256"][0, 12]}`)" }
      parts << "#{evidence["console_errors"].size} console errors" if evidence["console_errors"]
      parts << "#{evidence["network_errors"].size} failed requests" if evidence["network_errors"]
      parts.concat(Array(evidence["links"]).each_with_index.map { |link, index| "[link #{index + 1}](#{link})" })
      if (check = evidence["trace_check"])
        parts << (check["status"] == "verified" ? "trace verified: revision `#{check["revision"]}`, #{check["requests"]} requests" :
                                                  "trace check failed: #{Markdown.escape(check["findings"].first)}")
      end
      parts.empty? ? "none" : parts.join("<br>")
    end

    def markdown_excluded(entry)
      "- #{Markdown.escape(entry["name"])}: #{Markdown.escape(entry["reason"])}"
    end
  end
end
