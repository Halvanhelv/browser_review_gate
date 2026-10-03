require "json"

module BrowserReviewGate
  # Publishes locally observed browser results to the PR, or saves them until the PR exists.
  class Publisher
    # Without `number` the PR of the current branch is used. Without `report_path` the report saved for
    # the current commit is used.
    def initialize(github:, number: nil, report_path: nil, config: Config.new, shell: Shell.new)
      @github = github
      @number = number
      @report_path = report_path
      @config = config
      @shell = shell
    end

    # Returns true when the PR is verified, false when the report was published but does not pass.
    def publish
      number = @number || @github.pull_request_number_for_branch
      raise Error, "This branch has no pull request yet; save the run with --save instead" unless number

      pull_request = @github.pull_request(number)
      local_sha = head_sha
      ensure_clean_worktree!
      pr_sha = pull_request.fetch("head").fetch("sha")
      raise Error, "Local HEAD #{local_sha} does not match the PR head #{pr_sha}" unless pr_sha == local_sha

      saved_report = SavedReport.new(sha: local_sha, shell: @shell)
      data = load_report(saved_report)
      ensure_report_sha!(data, local_sha)
      actor = @github.login
      data["verified_by"] = "AI browser agent (run by #{actor})"

      comments = @github.comments(number)
      ensure_browser_run_wanted!(number, comments, local_sha)
      report = merged_report(data, comments)

      complete = report.passed?
      labelled = pull_request.fetch("labels").any? { |label| label["name"] == @config.label }
      @github.remove_label(number, @config.label) if labelled && !complete
      write_comment(number, comments, actor, body(report, complete))
      @github.add_label(number, @config.label) if complete
      saved_report.delete unless @report_path
      complete
    rescue KeyError => error
      raise Error, "Browser verification data is incomplete: #{error.message}"
    rescue JSON::ParserError => error
      raise Error, "Browser verification data is not valid JSON: #{error.message}"
    end

    # Keeps the results of a run made before the PR exists. Returns the path they were saved to.
    def save
      local_sha = head_sha
      ensure_clean_worktree!
      data = read_report_file
      ensure_report_sha!(data, local_sha)
      report = Report.new(data.merge("verified_by" => "pending"))
      raise Error, report.errors.join("; ") unless report.valid?

      saved_report = SavedReport.new(sha: local_sha, shell: @shell)
      saved_report.write(data)
      saved_report.path
    rescue JSON::ParserError => error
      raise Error, "Browser verification data is not valid JSON: #{error.message}"
    end

    private

    def head_sha = @shell.call("git", "rev-parse", "HEAD").strip

    # An untracked file may be code the browser run depended on, so it blocks publishing too.
    def ensure_clean_worktree!
      changes = @shell.call("git", "status", "--porcelain").lines.map(&:chomp)
      return if changes.empty?

      raise Error, "Commit and push changes before publishing browser verification, or remove these files:\n" \
        "#{changes.join("\n")}"
    end

    def ensure_report_sha!(data, sha)
      return if data.is_a?(Hash) && data["tested_sha"] == sha

      raise Error, "Report tested_sha must match the current commit #{sha}"
    end

    def load_report(saved_report)
      return read_report_file if @report_path
      return saved_report.read if saved_report.exist?

      raise Error, "No saved browser verification report for the current commit"
    end

    def read_report_file
      raise Error, "A report file is required" unless @report_path

      JSON.parse(File.read(@report_path))
    rescue SystemCallError => error
      raise Error, "Cannot read report file #{@report_path}: #{error.message}"
    end

    # A report made before the PR existed may arrive before the gate has assessed the commit.
    def ensure_browser_run_wanted!(number, comments, tested_sha)
      assessment = Assessment.latest(comments)
      return unless assessment&.for?(tested_sha)

      raise Error, "PR #{number} is not marked as requiring browser testing" unless assessment.required?
    end

    def merged_report(data, comments)
      submitted = Report.new(data)
      raise Error, submitted.errors.join("; ") unless submitted.valid?

      prior = Report.latest_comment(comments)
      report = Report.merge(prior ? Report.data_from(prior["body"]) : {}, submitted.to_h)
      raise Error, report.errors.join("; ") unless report.valid?

      report
    end

    def body(report, complete)
      return report.markdown if complete

      [ "**Not verified.** Complete every required browser scenario and pass all reported cases before human review.",
        "", report.markdown ].join("\n")
    end

    # Only the author's own earlier report comment can be edited in place.
    def write_comment(number, comments, actor, body)
      prior = Report.latest_comment(comments)
      if prior && prior.dig("user", "login") == actor
        @github.update_comment(prior.fetch("id"), body)
      else
        @github.create_comment(number, body)
      end
    end
  end
end
