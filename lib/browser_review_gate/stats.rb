module BrowserReviewGate
  # What the gate did on recent pull requests, read back from its own comments and labels.
  class Stats
    def initialize(github:, config: Config.new)
      @github = github
      @config = config
    end

    def to_h(since:)
      counts = Hash.new(0)
      @github.pull_requests_updated_since(since).each { |pull_request| count(pull_request, counts) }
      %w[pull_requests assessed required verified waived owed found_a_failure].to_h { |key| [ key, counts[key] ] }
    end

    private

    def count(pull_request, counts)
      counts["pull_requests"] += 1
      comments = @github.trusted_comments(pull_request.fetch("number"))
      assessment = Assessment.latest(comments)
      return unless assessment

      counts["assessed"] += 1
      return unless assessment.required?

      labels = Array(pull_request["labels"]).map { |label| label["name"] }
      counts["required"] += 1
      counts["verified"] += 1 if labels.include?(@config.label)
      counts["waived"] += 1 if labels.include?(@config.waiver_label)
      counts["owed"] += 1 if pull_request["state"] == "open" && !labels.intersect?([ @config.label, @config.waiver_label ])
      counts["found_a_failure"] += 1 if Report.latest(comments)&.failed_runs.to_i.positive?
    end
  end
end
