require "json"
require "stringio"

module BrowserReviewGate
  # Checks a project's setup and says what to fix. A check that cannot be verified from here is SKIP,
  # never PASS. Nothing secret is printed: secrets are checked by name only.
  class Doctor
    Check = Struct.new(:name, :status, :message, :fix) do
      def to_h = { "name" => name, "status" => status, "message" => message, "fix" => fix }.compact
    end

    SECRETS = %w[CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY].freeze
    BROWSER_TOOLS = { "playwright" => "Playwright", "chrome-devtools" => "Chrome DevTools MCP", "browsermcp" => "Browser MCP",
                      "puppeteer" => "Puppeteer" }.freeze
    AGENT_FILES = {
      "claude" => [ ".claude/skills/browser-pr-verification/SKILL.md", ".claude/settings.json" ],
      "cursor" => [ ".cursor/commands/browser-pr-verification.md", ".cursor/hooks.json" ],
      "codex" => [ "AGENTS.md", ".codex/hooks.json" ]
    }.freeze

    # `probe` takes a URL and says whether something answers there.
    # `header_probe` takes a URL and a header name and returns the header's value there, or nil.
    def initialize(root:, shell: Shell.new, github: nil, probe: nil, config_loader: nil, header_probe: nil)
      @header_probe = header_probe || Status.method(:header_at)
      @root = root
      @shell = shell
      @github = github
      @probe = probe || Status.method(:answers?)
      @config_loader = config_loader || -> { Config.load(root) }
    end

    def checks
      @checks = []
      ruby
      gem_executable
      repository
      config = configuration
      gh_ready = github_cli
      repository_access if gh_ready
      environments(config) if config
      agents(config)
      browser_tools(config)
      workflow(config) if config
      required_check(config) if config && gh_ready
      provider_secrets(config) if config && gh_ready
      @checks
    end

    def self.text(checks)
      width = checks.map { |check| check.name.length }.max.to_i
      lines = checks.map do |check|
        line = "#{check.status.ljust(4)}  #{check.name.ljust(width)}  #{check.message}"
        check.fix ? "#{line}\n#{" " * (width + 8)}fix: #{check.fix}" : line
      end
      counts = %w[PASS WARN FAIL SKIP].map { |status| "#{checks.count { |check| check.status == status }} #{status}" }
      (lines + [ "", counts.join(", ") ]).join("\n")
    end

    def self.json(checks) = JSON.pretty_generate("checks" => checks.map(&:to_h), "ok" => checks.none? { |check| check.status == "FAIL" })

    private

    def add(name, status, message, fix = nil) = @checks << Check.new(name, status, message, fix)
    def exist?(path) = File.exist?(File.join(@root, path))
    def read(path) = exist?(path) ? File.read(File.join(@root, path)) : ""

    def run(*argv)
      @shell.call(*argv)
    rescue Error
      nil
    end

    def ruby
      return add("ruby", "PASS", "Ruby #{RUBY_VERSION}") if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")

      add("ruby", "FAIL", "Ruby #{RUBY_VERSION} is older than 3.2", "Use Ruby 3.2 or newer")
    end

    def gem_executable
      found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "browser-review-gate")) }
      return add("gem", "PASS", "browser_review_gate #{VERSION} runs; a browser-review-gate executable is on PATH") if found

      add("gem", "WARN", "browser_review_gate #{VERSION} runs, but browser-review-gate is not on PATH",
        "bundle add browser_review_gate --group development, or run it with bundle exec")
    end

    def repository
      top = run("git", "rev-parse", "--show-toplevel")
      return add("repository", "PASS", "git repository at #{top.strip}") if top

      add("repository", "FAIL", "not inside a git repository", "Run from the project checkout")
    end

    def configuration
      config = @config_loader.call
      add("settings", exist?(Config::PATH) ? "PASS" : "WARN", exist?(Config::PATH) ? "#{Config::PATH} is valid" : "#{Config::PATH} is missing; defaults apply",
        exist?(Config::PATH) ? nil : "browser-review-gate install")
      config
    rescue Error => error
      add("settings", "FAIL", error.message, "Fix #{Config::PATH}")
      nil
    end

    def github_cli
      unless run("gh", "--version")
        add("gh", "FAIL", "the GitHub CLI is not installed", "Install gh: https://cli.github.com")
        return false
      end
      unless run("gh", "auth", "status")
        add("gh", "FAIL", "the GitHub CLI is not signed in", "gh auth login")
        return false
      end

      add("gh", "PASS", "installed and signed in")
      true
    end

    def repository_access
      github = @github || GitHub.new(shell: @shell)
      name = github.repository
      push = run("gh", "api", "repos/#{name}", "--jq", ".permissions.push").to_s.strip
      return add("repository access", "PASS", "#{name}: you can push, so your reports count") if push == "true"
      return add("repository access", "WARN", "#{name}: you cannot push; reports you publish are ignored", "Ask for write access") if push == "false"

      add("repository access", "SKIP", "#{name}: permissions could not be read")
    rescue Error => error
      add("repository access", "FAIL", error.message.lines.first.to_s.strip, "Check that the repository has a GitHub remote")
    end

    def environments(config)
      return add("environments", "WARN", "no environment is configured", "Add environments.local.url in #{Config::PATH}") if config.environments.empty?

      config.environments.each do |name, settings|
        next add("environment #{name}", "WARN", "no url", "Set environments.#{name}.url") unless settings["url"]

        url = Status.healthcheck_url(settings.merge("name" => name))
        if @probe.call(url)
          add("environment #{name}", "PASS", "answers at #{url}")
          revision_header(config, name, settings["url"])
        else
          add("environment #{name}", "WARN", "does not answer at #{url}",
            settings["start_command"] ? "Start it with #{settings["start_command"]} before a run" : "Make it reachable from where the agent runs")
        end
      end
    end

    # With trace checks on, a run can only count when the app names the commit it serves.
    def revision_header(config, name, url)
      mode = config.provenance["trace"]
      return if mode == "off"

      header = config.provenance["revision_header"]
      served = @header_probe.call(url, header).to_s.strip.downcase
      head = run("git", "-C", @root, "rev-parse", "HEAD").to_s.strip
      label = "revision header #{name}"
      fix = "Add `config.middleware.use BrowserReviewGate::RevisionHeader` to config/environments/development.rb"
      return add(label, mode == "require" ? "FAIL" : "WARN", "#{url} sends no #{header} header; traces cannot be checked", fix) if served.empty?
      return add(label, "PASS", "#{header} matches the checked-out commit") if !head.empty? && head.start_with?(served)

      add(label, "WARN", "#{header} is #{served[0, 12]}, the checkout is at #{head[0, 12]}",
        "Serve the checked-out code (restart the server, or run it from this worktree)")
    end

    def agents(config)
      installer = Installer.new(root: @root, log: StringIO.new)
      installer.detect_agents.each do |agent|
        entry, hooks = AGENT_FILES.fetch(agent)
        wired = agent == "codex" ? read(entry).include?("browser_review_gate:start") : exist?(entry)
        hooked = read(hooks).include?("browser-review-gate hook #{agent}")
        if wired && hooked
          add("agent #{agent}", "PASS", "instructions and post-command hook installed")
        else
          add("agent #{agent}", "WARN", [ wired ? nil : "#{entry} missing", hooked ? nil : "hook missing in #{hooks}" ].compact.join("; "),
            "browser-review-gate install --agents #{agent}")
        end
      end
      add("playbook", exist?(Installer::PLAYBOOK) ? "PASS" : "WARN", exist?(Installer::PLAYBOOK) ? Installer::PLAYBOOK : "#{Installer::PLAYBOOK} missing",
        exist?(Installer::PLAYBOOK) ? nil : "browser-review-gate install")
      rules = Prompts.new(@root).rules
      add("project rules", rules ? "PASS" : "WARN", rules ? "#{Prompts::RULES} has rules" : "#{Prompts::RULES} has no rules yet",
        rules ? nil : "Describe what this application always checks")
      config
    end

    # Only what the project's own files show. A tool configured elsewhere cannot be seen from here.
    def browser_tools(config)
      files = [ ".mcp.json", ".cursor/mcp.json", ".codex/config.toml", ".claude/settings.json", "package.json" ]
      text = files.map { |path| read(path) }.join("\n").downcase
      found = BROWSER_TOOLS.select { |key, _label| text.include?(key) }.values
      if found.any?
        add("browser tool", "PASS", "configured in the project: #{found.join(", ")}")
      else
        add("browser tool", "SKIP", "none found in the project's files; one may be configured per user",
          "Give the agent a browser tool, e.g. Playwright MCP or Chrome DevTools MCP")
      end
      trace_tool(config, text) if config
    end

    # With trace checks on, every case needs a Playwright trace or a HAR file. Only Playwright is known
    # to write both; other tools may write HAR, but that cannot be told from here.
    def trace_tool(config, text)
      mode = config.provenance["trace"]
      return if mode == "off"
      return add("trace recording", "PASS", "Playwright is configured in the project; it records traces and HAR files") if text.include?("playwright")

      add("trace recording", mode == "require" ? "WARN" : "SKIP",
        "provenance.trace is #{mode}, and no Playwright is configured in the project's files. Each case needs a Playwright " \
        "trace (.zip) or a HAR file (.har); a browser tool that cannot save either #{mode == "require" ? "gets every passing case refused" : "gets no check"}",
        "Give the agent Playwright (e.g. Playwright MCP), or a tool that saves HAR files, or set provenance.trace to warn or off")
    end

    def workflow(config)
      path = ".github/workflows/#{config.workflow}"
      return add("workflow", "FAIL", "#{path} is missing", "browser-review-gate install") unless exist?(path)

      version = read(path)[/browser_review_gate:managed (\S+)/, 1]
      return add("workflow", "PASS", "#{path} (#{version})") if version == VERSION
      return add("workflow", "SKIP", "#{path} was not written by the installer; cannot tell its version") unless version

      add("workflow", "WARN", "#{path} was written by #{version}; this is #{VERSION}", "browser-review-gate install")
    end

    def required_check(config)
      github = @github || GitHub.new(shell: @shell)
      branch = run("gh", "api", "repos/#{github.repository}", "--jq", ".default_branch").to_s.strip
      return add("required check", "SKIP", "the default branch could not be read") if branch.empty?

      contexts = run("gh", "api", "repos/#{github.repository}/branches/#{branch}/protection/required_status_checks", "--jq", ".contexts[]")
      return add("required check", "SKIP", "branch protection of #{branch} could not be read (needs admin access, or none is set)",
        "To block merging, make #{config.status_context} a required status check") unless contexts
      return add("required check", "PASS", "#{config.status_context} is required on #{branch}") if contexts.lines.map(&:strip).include?(config.status_context)

      add("required check", "WARN", "#{config.status_context} is not required on #{branch}; the gate does not block merging",
        "Make #{config.status_context} a required status check")
    rescue Error
      add("required check", "SKIP", "could not be checked")
    end

    def provider_secrets(config)
      return add("model credentials", "SKIP", "not needed: assessment is local, CI calls no model") if config.local?

      names = run("gh", "secret", "list", "--json", "name", "--jq", ".[].name")
      return add("model credentials", "SKIP", "repository secrets could not be listed (needs admin access)") unless names

      present = names.lines.map(&:strip) & SECRETS
      return add("model credentials", "FAIL", "no model secret in the repository", "Add one of #{SECRETS.join(", ")}") if present.empty?
      if config.provider.to_s.match?(/\A(openai|gemini)\z/) && config.model.nil?
        return add("model credentials", "FAIL", "#{config.provider} needs `model`", "Set model in #{Config::PATH}")
      end

      add("model credentials", "PASS", "secret present: #{present.join(", ")}")
    end
  end
end
