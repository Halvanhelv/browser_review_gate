require "json"

module BrowserReviewGate
  # Runs around an agent's shell commands.
  #
  # After a command that opened a PR, the browser run saved for this commit is published.
  # Before a command that opens a PR or asks for review, the agent is told when a browser run is still
  # owed, so the request is not made only to be taken back. It never fails the agent's session.
  class Hook
    OPEN_PR = "gh pr create"
    REVIEW_REQUEST = /gh pr (create|edit)\b.*(--reviewer|--add-reviewer|-r )|requested_reviewers/
    SKIP = "BROWSER_REVIEW_GATE_SKIP=1"

    def initialize(publisher_factory:, status_factory: nil, config: Config.new, shell: Shell.new)
      @publisher_factory = publisher_factory
      @status_factory = status_factory
      @config = config
      @shell = shell
    end

    # `payload` is the raw hook input. Returns a message for the agent, or nil when nothing was done.
    def after(payload)
      return unless payload.to_s.include?(OPEN_PR)
      return unless saved_run?

      verified = @publisher_factory.call.publish
      verified ? "Saved browser verification published; human review can be requested." :
                 "Saved browser results published, but some required cases still need to pass."
    rescue Error => error
      "Saved browser verification was not published: #{error.message}"
    end

    # Returns the reason the command should wait, or nil to let it run.
    def before(payload)
      text = payload.to_s
      return if text.include?(SKIP)

      reason = review_request_reason(text) if text.match?(REVIEW_REQUEST)
      reason ||= open_pr_reason if text.include?(OPEN_PR)
      reason && "#{reason} If the person asked to go ahead anyway, run the same command prefixed with #{SKIP}."
    rescue Error
      nil
    end

    # Claude Code and Codex read a JSON object; Cursor reads its own shape.
    def self.render(message, agent, before: false)
      return if message.nil?
      return JSON.generate(permission: "deny", agentMessage: message, userMessage: message) if before && agent == "cursor"
      return message unless %w[claude codex].include?(agent)
      return JSON.generate(hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: message }) unless before

      JSON.generate(hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: message })
    end

    private

    def saved_run?
      SavedReport.new(sha: @shell.call("git", "rev-parse", "HEAD").strip, shell: @shell).exist?
    end

    # No PR exists yet, so CI has not decided; only the changed paths can tell.
    def open_pr_reason
      return if saved_run? || changed_files.all? { |path| @config.ignored?(path) }

      "No browser run is saved for this commit, and the change may alter browser behavior. " \
        "Run #{@config.command} first: the run is published when the PR is opened and review requests stay."
    end

    def review_request_reason(text)
      status = @status_factory.call.to_h(text[/gh pr edit\s+(\d+)/, 1]&.to_i)
      case status["next"]
      when "publish_saved" then "A browser run is saved but not published. Run `browser-review-gate publish` first, or the review request will be taken back."
      when "run_and_publish", "ask_to_start_app" then "This PR needs a browser run (#{@config.command} #{status["pull_request"]}); a review request made now will be taken back."
      end
    end

    # What the PR would contain. When no base branch can be found the change counts as unknown.
    def changed_files
      %w[origin/HEAD origin/main origin/master].each do |base|
        return @shell.call("git", "diff", "--name-only", "#{base}...HEAD").lines.map(&:chomp)
      rescue Error
        next
      end
      [ "unknown" ]
    end
  end
end
