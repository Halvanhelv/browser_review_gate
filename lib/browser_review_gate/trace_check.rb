require "json"
require "time"
require "uri"

module BrowserReviewGate
  # Reads a Playwright trace (trace.zip) and checks that it shows the case really ran against the
  # tested code: a response carried the app's revision header with the tested commit, the case's page
  # was requested, and the requests fall inside the run's time window.
  #
  # This catches an agent that reports a run it did not do. It does not stop someone who builds a
  # trace by hand; a trace is a file like any other.
  class TraceCheck
    NETWORK_ENTRY = /(?:\A|\/)(?:\d+-)?trace\.network\z/

    def initialize(config)
      @settings = config.provenance
    end

    # Returns { "status" => "verified" | "failed", "revision" => ..., "requests" => n, "findings" => [...] }.
    def call(path, tested_sha:, url:, started_at:, finished_at:)
      requests = read(path)
      findings = []
      revisions = requests.filter_map { |request| request[:revision] }.uniq
      matched = revisions.find { |revision| tested_sha.start_with?(revision) }
      if revisions.empty?
        findings << "no response carried the #{@settings["revision_header"]} header"
      elsif matched.nil?
        findings << "the app answered with revision #{revisions.first[0, 12]}, not the tested commit"
      end
      findings << "the case's page #{url} was not requested" if @settings["check_pages"] && url && !page_requested?(requests, url)
      findings.concat(time_findings(requests, started_at, finished_at))
      findings << "the trace has no network requests" if requests.empty?

      { "status" => findings.empty? ? "verified" : "failed", "revision" => matched && tested_sha[0, 12],
        "requests" => requests.size, "findings" => findings.first(5) }.compact
    end

    private

    def read(path)
      requests = []
      ZipReader.new(path).each(->(name) { NETWORK_ENTRY.match?(name) }) do |_name, content|
        content.each_line do |line|
          request = parse(line)
          requests << request if request
        end
      end
      requests
    end

    # One HAR-like resource snapshot per line; anything else is skipped.
    def parse(line)
      event = JSON.parse(line)
      snapshot = event.is_a?(Hash) && event["type"] == "resource-snapshot" ? event["snapshot"] : nil
      return unless snapshot.is_a?(Hash) && snapshot["request"].is_a?(Hash)

      headers = snapshot.dig("response", "headers")
      header = Array(headers).find { |entry| entry.is_a?(Hash) && entry["name"].to_s.casecmp?(@settings["revision_header"]) }
      { url: snapshot["request"]["url"].to_s, time: time(snapshot["startedDateTime"]),
        revision: header && header["value"].to_s.strip.downcase[/\A\h{7,40}\z/] }
    rescue JSON::ParserError
      nil
    end

    def time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # The case's page counts as requested when a request has the same path, and the same host when
    # the case names a full URL.
    def page_requested?(requests, url)
      wanted = URI.parse(url)
      requests.any? do |request|
        seen = URI.parse(request[:url])
        seen.path.to_s.chomp("/") == wanted.path.to_s.chomp("/") && (wanted.host.nil? || wanted.host == seen.host)
      rescue URI::InvalidURIError
        false
      end
    rescue URI::InvalidURIError
      false
    end

    def time_findings(requests, started_at, finished_at)
      return [] unless started_at && finished_at

      skew = @settings["clock_skew_seconds"]
      from = Time.iso8601(started_at) - skew
      to = Time.iso8601(finished_at) + skew
      times = requests.filter_map { |request| request[:time] }
      return [ "the trace has no request times" ] if times.empty? && requests.any?
      return [] if times.empty?

      outside = times.count { |seen| seen < from || seen > to }
      outside.positive? ? [ "#{outside} of #{times.size} requests fall outside the run's started_at..finished_at" ] : []
    rescue ArgumentError
      []
    end
  end
end
