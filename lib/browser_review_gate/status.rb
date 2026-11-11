require "net/http"
require "openssl"
require "uri"
require "stringio"

module BrowserReviewGate
  # What an agent needs to know before a browser run: the decision for the PR head, the scenarios still
  # owed with their status, the environment to use, the policy, and the next step.
  class Status
    RUN_STEPS = %w[run_and_publish run_and_save].freeze

    # `probe` takes a URL and says whether something answers there.
    def initialize(github:, config: Config.new, shell: Shell.new, probe: nil, prompts: Prompts.new)
      @prompts = prompts
      @github = github
      @config = config
      @shell = shell
      @probe = probe || Status.method(:answers?)
    end

    def to_h(number = nil, environment: nil)
      result = facts(number)
      # "local": the agent chooses the scenarios (the list holds only the mandatory ones) and may report
      # that no run is needed, with a reason. "ci": the list is complete; run exactly that.
      result["assessment"] = @config.assessment
      result["project_rules"] = Prompts::RULES if @prompts.rules
      result["environment"] = environment_details(environment)
      result["policy"] = @config.policy
      result["report"] = report_instructions
      # The agent never starts the app itself: a person decides what runs on their machine.
      result["next"] = "ask_to_start_app" if RUN_STEPS.include?(result["next"]) && result["environment"]["reachable"] == false
      result
    end

    # Any HTTP answer counts, redirects are not followed, and only http(s) is tried. A local
    # certificate is not checked. The URL comes from the project settings.
    def self.answers?(url)
      uri = URI(url)
      return false unless %w[http https].include?(uri.scheme) && uri.host

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", verify_mode: OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 2, read_timeout: 3) { |http| http.head(uri.request_uri) }
      true
    rescue StandardError
      false
    end

    # The value of `header` in the answer at `url`, or nil. Same limits as answers?.
    def self.header_at(url, header)
      uri = URI(url)
      return unless %w[http https].include?(uri.scheme) && uri.host

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", verify_mode: OpenSSL::SSL::VERIFY_NONE,
        open_timeout: 2, read_timeout: 3) { |http| http.head(uri.request_uri)[header] }
    rescue StandardError
      nil
    end

    # The URL a health check asks: an absolute `healthcheck`, or its path on the environment URL.
    def self.healthcheck_url(environment)
      check = environment["healthcheck"]
      return environment["url"] if check.nil?
      return check if check.start_with?("http://", "https://")

      URI.join(environment["url"], check).to_s
    end

    private

    def facts(number)
      local_sha = @shell.call("git", "rev-parse", "HEAD").strip
      saved = SavedReport.new(sha: local_sha, shell: @shell).exist?
      number ||= @github.pull_request_number_for_branch
      unless number
        return { "pull_request" => nil, "local_head" => local_sha, "saved_run" => saved, "scenarios" => [],
                 "next" => saved ? "open_pull_request" : "run_and_save" }
      end

      pull_request = @github.pull_request(number)
      comments = @github.trusted_comments(number)
      head_sha = pull_request.fetch("head").fetch("sha")
      assessment = Assessment.latest(comments)
      assessment = nil unless assessment&.for?(head_sha)
      # In local mode the decision needs no model, so it is made here when CI has not written it yet.
      assessment ||= Assessor.new(github: @github, model: nil, config: @config, log: StringIO.new).propose_locally(number, head_sha) if @config.local?
      labels = pull_request.fetch("labels").map { |label| label["name"] }
      report = Report.latest(comments, config: @config)
      commits = @github.pull_request_commits(number)
      reuse = @config.scenarios["reuse_passing"]
      fresh = assessment&.local? && Freshness.new(github: @github, config: @config).fresh?(report, head_sha)
      verified = labels.include?(@config.label) && assessment&.covered_by?(report, commits: commits, reuse_passing: reuse, fresh: fresh) == true
      waived = labels.include?(@config.waiver_label)

      { "pull_request" => number, "pr_head" => head_sha, "local_head" => local_sha,
        "decision" => assessment&.decision, "reason" => assessment&.reason,
        # What the run must exercise; each id is the `id` of the case that reports it.
        "scenarios" => assessment ? scenarios(assessment, report, commits, reuse) : [], "verified" => verified, "waived" => waived,
        "saved_run" => saved, "next" => next_step(assessment, verified || waived, saved, head_sha == local_sha) }
    end

    def scenarios(assessment, report, commits, reuse)
      assessment.outstanding(report, commits: commits, reuse_passing: reuse).map do |scenario|
        scenario.merge("status" => report ? report.status_of(scenario["id"], commits: commits) : "missing")
      end
    end

    def next_step(assessment, cleared, saved, on_pr_head)
      return "nothing" if cleared || (assessment && !assessment.required?)
      return "check_out_pr_head" unless on_pr_head
      return "publish_saved" if saved
      return "request_assessment" unless assessment

      "run_and_publish"
    end

    def environment_details(name)
      environment = @config.environment(name)
      return { "name" => nil, "reachable" => nil, "note" => "No environment is configured in #{Config::PATH}." } unless environment

      details = environment.slice("name", "url", "healthcheck", "start_command", "sign_in")
      details["reachable"] = environment["url"] ? @probe.call(Status.healthcheck_url(environment)) : nil
      details
    end

    def report_instructions
      { "schema_version" => Report::SCHEMA_VERSION, "results" => Report::RESULTS, "capabilities" => Report::CAPABILITIES,
        "evidence_paths" => "relative to the directory of the report file, outside the repository" }
    end
  end
end
