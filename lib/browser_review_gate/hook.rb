require "json"

module BrowserReviewGate
  # Runs after an agent's shell command. When the command opened a PR, the browser run saved for this
  # commit is published. Never fails the agent: every outcome is reported as a message.
  class Hook
    TRIGGER = "gh pr create"

    def initialize(publisher_factory:, shell: Shell.new)
      @publisher_factory = publisher_factory
      @shell = shell
    end

    # `payload` is the raw hook input. Returns a message for the agent, or nil when nothing was done.
    def call(payload)
      return unless payload.to_s.include?(TRIGGER)

      sha = @shell.call("git", "rev-parse", "HEAD").strip
      return unless SavedReport.new(sha: sha, shell: @shell).exist?

      verified = @publisher_factory.call.publish
      verified ? "Saved browser verification published; human review can be requested." :
                 "Saved browser results published, but some required cases still need to pass."
    rescue Error => error
      "Saved browser verification was not published: #{error.message}"
    end

    # Claude Code reads a JSON object; other agents show plain text.
    def self.render(message, agent)
      return if message.nil?
      return message unless agent == "claude"

      JSON.generate(hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: message })
    end
  end
end
