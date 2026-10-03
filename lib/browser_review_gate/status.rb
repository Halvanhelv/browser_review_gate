module BrowserReviewGate
  # What an agent needs to know before a browser run: the decision for the PR head and the next step.
  class Status
    def initialize(github:, config: Config.new, shell: Shell.new)
      @github = github
      @config = config
      @shell = shell
    end

    def to_h(number = nil)
      local_sha = @shell.call("git", "rev-parse", "HEAD").strip
      saved = SavedReport.new(sha: local_sha, shell: @shell).exist?
      number ||= @github.pull_request_number_for_branch
      return { "pull_request" => nil, "local_head" => local_sha, "saved_run" => saved, "next" => saved ? "open_pull_request" : "run_and_save", "app" => @config.app } unless number

      pull_request = @github.pull_request(number)
      comments = @github.comments(number)
      head_sha = pull_request.fetch("head").fetch("sha")
      assessment = Assessment.latest(comments)
      assessment = nil unless assessment&.for?(head_sha)
      verified = pull_request.fetch("labels").any? { |label| label["name"] == @config.label } && !Report.latest_passing(comments).nil?

      { "pull_request" => number, "pr_head" => head_sha, "local_head" => local_sha,
        "decision" => assessment&.decision, "reason" => assessment&.reason, "verified" => verified,
        "saved_run" => saved, "next" => next_step(assessment, verified, saved, head_sha == local_sha),
        "app" => @config.app }
    end

    private

    def next_step(assessment, verified, saved, on_pr_head)
      return "nothing" if assessment && (!assessment.required? || verified)
      return "check_out_pr_head" unless on_pr_head
      return "publish_saved" if saved
      return "request_assessment" unless assessment

      "run_and_publish"
    end
  end
end
