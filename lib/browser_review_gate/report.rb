require "json"

module BrowserReviewGate
  # The browser cases an agent actually ran, with their outcomes. Published as one PR comment.
  class Report
    MARKER = /<!--\s*browser-verification-report:([A-Za-z0-9_-]+)\s*-->/
    SHA_PATTERN = /\A\h{7,40}\z/
    CASE_ID_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
    RESULTS = %w[pass fail].freeze

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

    # The newest passing report on the PR, or nil.
    def self.latest_passing(comments)
      comment = latest_comment(comments)
      report = comment && new(data_from(comment["body"]))
      report if report&.passed?
    rescue Error
      nil
    end

    # Later results replace earlier ones case by case; cases that were not run again are kept.
    def self.merge(previous_data, latest_data)
      previous = new(previous_data)
      latest = new(latest_data)
      return latest unless previous.valid? && latest.valid?

      combined = previous.cases.to_h { |test_case| [ test_case["id"], test_case ] }
      latest.cases.each { |test_case| combined[test_case["id"]] = test_case }
      new(latest.to_h.merge("cases" => combined.values))
    end

    def initialize(data)
      @errors = []
      @data = normalize(data.is_a?(Hash) ? data : {})
      attach_defaults_to_cases
      validate
    end

    def valid? = errors.empty?
    def tested_sha = @data["tested_sha"]
    def verified_by = @data["verified_by"]
    def cases = @data["cases"].is_a?(Array) ? @data["cases"] : []
    def excluded = @data["excluded"].is_a?(Array) ? @data["excluded"] : []
    def to_h = JSON.parse(JSON.generate(@data))

    def passed?
      valid? && @data["coverage_complete"] && cases.all? { |test_case| test_case["result"] == "pass" }
    end

    def markdown
      return "Browser verification report is invalid: #{errors.map { |error| Markdown.escape(error) }.join("; ")}" unless valid?

      coverage = @data["coverage_complete"] ? "Complete scenario run." : "Scenario run is incomplete."
      lines = [ "## Browser verification", "",
        "Verified by **#{Markdown.escape(verified_by)}** for commit `#{tested_sha}`.", coverage, "" ]
      lines.concat(cases.map { |test_case| markdown_case(test_case) })
      lines.concat([ "", "Not exercised in the browser, by the author's decision:" ] + excluded.map { |entry| markdown_excluded(entry) }) if excluded.any?
      payload = Marker.encode(JSON.generate(to_h))
      lines.concat([ "", "<!-- browser-verification-report:#{payload} -->" ]).join("\n")
    end

    private

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

        test_case["tested_sha"] ||= @data["tested_sha"]
        test_case["verified_by"] ||= @data["verified_by"]
      end
    end

    def validate
      errors << "tested_sha must be a 7–40 character hexadecimal commit SHA" unless sha?(@data["tested_sha"])
      errors << "verified_by must be a non-empty string of at most 100 characters" unless text?(@data["verified_by"], 100)
      errors << "coverage_complete must be true or false" unless [ true, false ].include?(@data["coverage_complete"])
      validate_cases
      validate_excluded
    end

    def validate_cases
      return errors << "cases must be a non-empty array" unless @data["cases"].is_a?(Array) && cases.any?

      seen_ids = []
      cases.each_with_index do |test_case, index|
        next errors << "case #{index + 1} must be an object" unless test_case.is_a?(Hash)

        validate_case(test_case, index + 1, seen_ids)
      end
    end

    def validate_case(test_case, position, seen_ids)
      id = test_case["id"]
      if !(id.is_a?(String) && CASE_ID_PATTERN.match?(id))
        errors << "case #{position} id must use letters, numbers, dots, underscores, or hyphens"
      elsif seen_ids.include?(id)
        errors << "case id #{id.inspect} appears more than once"
      else
        seen_ids << id
      end
      errors << "case #{position} name must be a non-empty string of at most 200 characters" unless text?(test_case["name"], 200)
      errors << "case #{position} result must be pass or fail" unless RESULTS.include?(test_case["result"])
      errors << "case #{position} tested_sha must be a 7–40 character hexadecimal commit SHA" unless sha?(test_case["tested_sha"])
      errors << "case #{position} verified_by must be a non-empty string of at most 100 characters" unless text?(test_case["verified_by"], 100)
      details = test_case["details"]
      errors << "case #{position} details must be a string of at most 500 characters" unless details.nil? || (details.is_a?(String) && details.length <= 500)
    end

    # Scenarios the author decided not to run locally, e.g. a sign-in through an external provider.
    def validate_excluded
      return if @data["excluded"].nil?
      return errors << "excluded must be an array" unless @data["excluded"].is_a?(Array)

      excluded.each_with_index do |entry, index|
        next if entry.is_a?(Hash) && text?(entry["name"], 200) && text?(entry["reason"], 500)

        errors << "excluded #{index + 1} needs a name and a reason"
      end
    end

    def sha?(value) = value.is_a?(String) && SHA_PATTERN.match?(value)
    def text?(value, limit) = value.is_a?(String) && !value.strip.empty? && value.length <= limit

    def markdown_case(test_case)
      detail = test_case["details"].to_s.empty? ? "" : ": #{Markdown.escape(test_case["details"])}"
      "- #{test_case["result"].upcase} — #{Markdown.escape(test_case["name"])} (`#{test_case["id"]}`, tested " \
        "`#{test_case["tested_sha"]}` by #{Markdown.escape(test_case["verified_by"])})#{detail}"
    end

    def markdown_excluded(entry)
      "- #{Markdown.escape(entry["name"])}: #{Markdown.escape(entry["reason"])}"
    end
  end
end
