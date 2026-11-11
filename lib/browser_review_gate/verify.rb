module BrowserReviewGate
  # One entry point for the verification workflow. Ruby does the bookkeeping: which PR, which decision,
  # which scenarios are still owed, which environment, whether the app answers, and publishing what an
  # agent observed. The browser run itself happens in the AI coding agent (Claude Code, Cursor, Codex)
  # with its browser tool; nothing here drives a browser.
  class Verify
    # Exit statuses, so an agent or a script can branch on the outcome.
    EXIT = {
      "nothing" => 0, "published" => 0, "saved" => 0,
      "run_and_publish" => 2, "run_and_save" => 2,
      "ask_to_start_app" => 3,
      "request_assessment" => 4, "assessment_requested" => 4,
      "check_out_pr_head" => 5, "open_pull_request" => 5,
      "publish_saved" => 6, "not_verified" => 7
    }.freeze

    def initialize(github:, config:, prompts:, shell: Shell.new, probe: nil, publisher_factory: nil)
      @github = github
      @config = config
      @prompts = prompts
      @shell = shell
      @probe = probe
      @publisher_factory = publisher_factory || lambda { |number, path|
        Publisher.new(github: github, number: number, report_path: path, config: config, shell: shell)
      }
    end

    # Returns [outcome, details]. `report` publishes (or saves, before the PR exists) a finished run.
    # `request` lets a missing assessment be requested from CI.
    def run(number: nil, environment: nil, report: nil, request: true)
      status = Status.new(github: @github, config: @config, shell: @shell, probe: @probe, prompts: @prompts).to_h(number, environment: environment)
      outcome = status["next"]
      return [ submit(status, report), status ] if report && %w[run_and_publish run_and_save publish_saved].include?(outcome)

      if outcome == "publish_saved"
        outcome = @publisher_factory.call(status["pull_request"], nil).publish ? "published" : "not_verified"
      elsif outcome == "request_assessment" && request
        @github.dispatch_workflow(@config.workflow, status["pull_request"])
        outcome = "assessment_requested"
      end
      [ outcome, status ]
    end

    def self.exit_status(outcome) = EXIT.fetch(outcome, 1)

    # What to tell the person or the agent for each outcome.
    def self.describe(outcome, status)
      environment = status["environment"] || {}
      case outcome
      when "nothing" then "Nothing to run: #{status["waived"] ? "verification was waived" : "no browser run is needed or the PR is verified"}. Human review can be requested."
      when "published" then "Browser verification published; human review can be requested."
      when "saved" then "Browser run saved. It is published when the PR for this commit is opened."
      when "not_verified" then "Results published, but required scenarios still need a passing case. Review stays on hold."
      when "assessment_requested" then "CI has been asked to assess PR #{status["pull_request"]}. Run verify again in about a minute."
      when "request_assessment" then "PR #{status["pull_request"]} has no assessment yet. Run verify without --no-request to ask CI for one."
      when "check_out_pr_head" then "Check out the PR head (#{status["pr_head"]}) with a clean worktree, then run verify again."
      when "open_pull_request" then "A run is saved for this commit. Open the pull request; it is published then."
      when "ask_to_start_app" then "The #{environment["name"]} environment does not answer at #{environment["url"]}. Ask the person to start it" \
        "#{environment["start_command"] ? " (#{environment["start_command"]})" : ""}; do not start it yourself."
      else run_instructions(status)
      end
    end

    def self.run_instructions(status)
      environment = status["environment"] || {}
      scenarios = status["scenarios"]
      list = scenarios.map { |scenario| "  - #{scenario["id"]} [#{scenario["status"]}] #{scenario["name"]}" }
      if status["assessment"] == "local"
        list << "  - and the scenarios you choose from the diff and #{Prompts::RULES} (assessment is local)"
        list << "  If nothing the change does can be seen in a browser, publish a report with \"not_required\": {\"reason\": ...} and no cases."
      elsif list.empty?
        list << "  - none listed by CI yet: choose them from the diff and #{Prompts::RULES}"
      end
      [ "A browser run is needed#{status["pull_request"] ? " for PR ##{status["pull_request"]}" : ""}.",
        "Environment: #{environment["name"] || "not configured"}#{environment["url"] ? " at #{environment["url"]}" : ""}.",
        "Scenarios to run in your browser tool, one case per id:", *list,
        *trace_note(status),
        "Then: browser-review-gate verify --report PATH (publishes, or saves before the PR exists)." ].join("\n")
    end

    def self.trace_note(status)
      mode = status.dig("policy", "enforced", "trace_check")
      return [] if mode.nil? || mode == "off"

      [ "Record a Playwright trace (.zip) or a HAR file (.har) for every case and list it as evidence.trace." \
        "#{mode == "require" ? " Without one, a passing case is refused. If your browser tool can save neither, stop and tell the person." : ""}" ]
    end

    private

    def submit(status, report)
      if status["pull_request"]
        @publisher_factory.call(status["pull_request"], report).publish ? "published" : "not_verified"
      else
        @publisher_factory.call(nil, report).save
        "saved"
      end
    end
  end
end
