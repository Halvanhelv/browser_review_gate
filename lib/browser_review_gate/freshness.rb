module BrowserReviewGate
  # Whether a report still speaks for the PR head in `assessment: local`, where no model re-reads the
  # diff: it was run on the head, or every file changed since the run is one that cannot reach the
  # browser (`ignore_paths`). Anything unknown counts as stale.
  class Freshness
    def initialize(github:, config:)
      @github = github
      @config = config
    end

    def fresh?(report, head_sha)
      return false unless report
      return true if report.tested_sha == head_sha

      files = @github.changed_files_between(report.tested_sha, head_sha)
      !files.nil? && files.all? { |path| @config.ignored?(path) }
    rescue Error
      false
    end
  end
end
