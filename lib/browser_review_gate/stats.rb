require "time"

module BrowserReviewGate
  # What the gate did on recent pull requests, read back from its own comments and labels. Only what
  # the comments record is counted: each PR keeps its latest assessment and its merged report, so
  # earlier assessments of the same PR and their token usage are not visible any more.
  class Stats
    COUNTS = %w[pull_requests assessed required verified waived owed found_a_failure runs failed_runs].freeze

    def initialize(github:, config: Config.new)
      @github = github
      @config = config
    end

    def to_h(since:)
      counts = Hash.new(0)
      failing = Hash.new(0)
      hours = []
      usage = { "assessments_with_usage" => 0, "input_tokens" => 0, "output_tokens" => 0, "assessments_with_cost" => 0, "cost_usd" => 0.0 }
      @github.pull_requests_updated_since(since).each { |pull_request| count(pull_request, counts, failing, hours, usage) }

      result = COUNTS.to_h { |key| [ key, counts[key] ] }
      result["failing_scenarios"] = failing.sort_by { |id, times| [ -times, id ] }.first(10).to_h
      result["hours_to_verification"] = hours.empty? ? nil : { "median" => median(hours).round(1), "measured" => hours.size }
      usage["cost_usd"] = usage["cost_usd"].round(4)
      result["assessment_usage"] = usage
      result
    end

    def self.text(result, days)
      lines = [ "Pull requests touched in the last #{days} days: #{result["pull_requests"]}",
        "  assessed by the gate:           #{result["assessed"]}",
        "  needed a browser run:           #{result["required"]}",
        "    verified by a published run:  #{result["verified"]}",
        "    waived:                       #{result["waived"]}",
        "    open and still owing a run:   #{result["owed"]}",
        "    a run found a failing case:   #{result["found_a_failure"]}",
        "  browser runs published:         #{result["runs"]} (#{result["failed_runs"]} with a failing case)" ]
      if (time = result["hours_to_verification"])
        lines << "  PR opened to verified run:      median #{time["median"]} h over #{time["measured"]} PRs"
      end
      result["failing_scenarios"].each_with_index do |(id, times), index|
        lines << "  #{index.zero? ? "failing scenarios:" : ""}".ljust(34) + "#{id} (#{times})"
      end
      usage = result["assessment_usage"]
      if usage["assessments_with_usage"].positive?
        lines << "  latest assessments, tokens:     #{usage["input_tokens"]} in, #{usage["output_tokens"]} out " \
                 "(#{usage["assessments_with_usage"]} reported)"
      end
      if usage["assessments_with_cost"].positive?
        lines << "  latest assessments, cost:       $#{usage["cost_usd"]} (#{usage["assessments_with_cost"]} reported by the provider)"
      end
      lines.join("\n")
    end

    private

    def count(pull_request, counts, failing, hours, usage)
      counts["pull_requests"] += 1
      number = pull_request.fetch("number")
      comments = @github.trusted_comments(number)
      assessment = Assessment.latest(comments)
      return unless assessment

      counts["assessed"] += 1
      add_usage(assessment.usage, usage)
      return unless assessment.required?

      labels = Array(pull_request["labels"]).map { |label| label["name"] }
      report = Report.latest(comments, config: @config)
      counts["required"] += 1
      counts["verified"] += 1 if labels.include?(@config.label)
      counts["waived"] += 1 if labels.include?(@config.waiver_label)
      counts["owed"] += 1 if pull_request["state"] == "open" && !labels.intersect?([ @config.label, @config.waiver_label ])
      return unless report

      counts["runs"] += report.runs
      counts["failed_runs"] += report.failed_runs
      counts["found_a_failure"] += 1 if report.failed_runs.positive?
      report.cases.each { |test_case| failing[test_case["id"]] += 1 if report.status_of(test_case["id"]) == "failed" }
      measure(pull_request, comments, labels, hours)
    end

    # From the PR being opened to the report comment's last update, for PRs that are verified now.
    def measure(pull_request, comments, labels, hours)
      return unless labels.include?(@config.label)

      comment = Report.latest_comment(comments)
      opened = pull_request["created_at"]
      published = comment && (comment["updated_at"] || comment["created_at"])
      return unless opened && published

      hours << (Time.iso8601(published) - Time.iso8601(opened)) / 3600.0
    rescue ArgumentError
      nil
    end

    def add_usage(found, usage)
      return unless found

      if found["input_tokens"] || found["output_tokens"]
        usage["assessments_with_usage"] += 1
        usage["input_tokens"] += found["input_tokens"].to_i
        usage["output_tokens"] += found["output_tokens"].to_i
      end
      return unless found["cost_usd"]

      usage["assessments_with_cost"] += 1
      usage["cost_usd"] += found["cost_usd"]
    end

    def median(values)
      sorted = values.sort
      middle = sorted.size / 2
      sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end
  end
end
