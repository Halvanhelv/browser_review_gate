require "net/http"
require "openssl"
require "uri"

module BrowserReviewGate
  # What an agent needs to know before a browser run: the decision for the PR head and the next step.
  class Status
    RUN_STEPS = %w[run_and_publish run_and_save].freeze

    # `probe` takes the app URL and says whether something answers there.
    def initialize(github:, config: Config.new, shell: Shell.new, probe: nil)
      @github = github
      @config = config
      @shell = shell
      @probe = probe || method(:answers?)
    end

    def to_h(number = nil)
      result = facts(number)
      result["project_rules"] = Prompts::RULES if Prompts.new.rules
      result["app"] = app
      # The agent never starts the app itself: a person decides what runs on their machine.
      result["next"] = "ask_to_start_app" if RUN_STEPS.include?(result["next"]) && result["app"]["running"] == false
      result
    end

    private

    def facts(number)
      local_sha = @shell.call("git", "rev-parse", "HEAD").strip
      saved = SavedReport.new(sha: local_sha, shell: @shell).exist?
      number ||= @github.pull_request_number_for_branch
      return { "pull_request" => nil, "local_head" => local_sha, "saved_run" => saved, "next" => saved ? "open_pull_request" : "run_and_save" } unless number

      pull_request = @github.pull_request(number)
      comments = @github.comments(number)
      head_sha = pull_request.fetch("head").fetch("sha")
      assessment = Assessment.latest(comments)
      assessment = nil unless assessment&.for?(head_sha)
      labels = pull_request.fetch("labels").map { |label| label["name"] }
      verified = labels.include?(@config.label) && !Report.latest_passing(comments).nil?
      waived = labels.include?(@config.waiver_label)

      { "pull_request" => number, "pr_head" => head_sha, "local_head" => local_sha,
        "decision" => assessment&.decision, "reason" => assessment&.reason, "verified" => verified, "waived" => waived,
        "saved_run" => saved, "next" => next_step(assessment, verified || waived, saved, head_sha == local_sha) }
    end

    def next_step(assessment, cleared, saved, on_pr_head)
      return "nothing" if cleared || (assessment && !assessment.required?)
      return "check_out_pr_head" unless on_pr_head
      return "publish_saved" if saved
      return "request_assessment" unless assessment

      "run_and_publish"
    end

    def app
      details = @config.app
      details["running"] = @probe.call(@config.url) if @config.url
      details
    end

    # Any HTTP answer counts; a local certificate is not checked.
    def answers?(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", verify_mode: OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 2, read_timeout: 3) { |http| http.head(uri.path.empty? ? "/" : uri.path) }
      true
    rescue StandardError
      false
    end
  end
end
