require "erb"
require "fileutils"
require "json"

module BrowserReviewGate
  # Sets a project up in one go: the CI workflow, the settings file, the agent playbook, and the
  # entry points for every AI coding agent the project uses. Safe to run again after a gem update.
  class Installer
    AGENTS = %w[claude cursor codex].freeze
    MANAGED = "browser_review_gate:managed"
    PLAYBOOK = "docs/browser-review-gate.md"
    HOOK = "browser-review-gate hook"
    BLOCK = /<!-- browser_review_gate:start -->.*?<!-- browser_review_gate:end -->\n?/m

    def initialize(root:, log: $stdout, agents: nil, gem_source: nil, workflow: nil, force: false, dry_run: false)
      @root = root
      @log = log
      @agents = agents
      @gem_source = gem_source
      @workflow = workflow
      @force = force
      @dry_run = dry_run
    end

    def install
      agents = @agents || detect_agents
      unknown = agents - AGENTS
      raise Error, "Unknown agents: #{unknown.join(", ")} (known: #{AGENTS.join(", ")})" if unknown.any?

      preflight(agents)
      create_only(Config::PATH, render("config.yml"))
      managed(".github/workflows/#{workflow}", render("workflow.yml"))
      managed(PLAYBOOK, render("playbook.md"))
      agents.each { |agent| send("install_#{agent}") }
      @log.puts "", "Agents: #{agents.join(", ")}.", next_steps
      agents
    end

    # Which AI coding agents the project is set up for. AGENTS.md is read by most of them, so it is
    # the fallback when nothing is found.
    def detect_agents
      found = []
      found << "claude" if exist?(".claude") || exist?("CLAUDE.md")
      found << "cursor" if exist?(".cursor") || exist?(".cursorrules")
      found << "codex" if exist?(".codex") || exist?("AGENTS.md")
      found.empty? ? [ "codex" ] : found
    end

    private

    def config = @config ||= Config.load(@root)
    def workflow = @workflow || config.workflow
    def command = config.command
    def label = config.label
    def playbook_path = PLAYBOOK
    def exist?(path) = File.exist?(File.join(@root, path))

    def start_command
      return "bin/dev" if exist?("bin/dev")

      "npm run dev" if exist?("package.json")
    end

    def url = exist?("config/application.rb") ? "http://localhost:3000" : nil

    # setup-ruby reads the project's own version file when there is one.
    def ruby_version = exist?(".ruby-version") || exist?(".tool-versions") ? nil : "3.4"

    # How CI gets the gem: from RubyGems, from a git repository ("git:URL" or "git:URL#REF"), or from a
    # copy kept in the project itself ("path:DIR", read from the base branch like the rest of the checkout).
    def install_command
      return "gem install browser_review_gate -v #{VERSION} --no-document" if @gem_source.nil? || @gem_source == "rubygems"
      return %(echo "$GITHUB_WORKSPACE/#{@gem_source.delete_prefix("path:")}/exe" >> "$GITHUB_PATH") if @gem_source.match?(%r{\Apath:[\w./-]+\z})

      url, ref = @gem_source.delete_prefix("git:").split("#", 2)
      raise Error, "--gem-source must be rubygems, git:URL[#REF] or path:DIR" unless @gem_source.start_with?("git:") && !url.to_s.empty?

      %(git clone --quiet --depth 1 --branch "#{ref || "v#{VERSION}"}" "#{url}" "$RUNNER_TEMP/browser_review_gate" && ) +
        %(echo "$RUNNER_TEMP/browser_review_gate/exe" >> "$GITHUB_PATH")
    end

    JSON_FILES = { "claude" => ".claude/settings.json", "cursor" => ".cursor/hooks.json", "codex" => ".codex/hooks.json" }.freeze

    # Nothing is written when a settings file that must be merged cannot be read.
    def preflight(agents)
      agents.filter_map { |agent| JSON_FILES[agent] }.each do |path|
        JSON.parse(File.read(File.join(@root, path))) if exist?(path)
      rescue JSON::ParserError
        raise Error, "#{path} is not valid JSON; fix it and run install again"
      end
    end

    def install_claude
      managed(".claude/skills/browser-pr-verification/SKILL.md", render("claude_skill.md"))
      merge_json(".claude/settings.json") do |settings|
        entries = ((settings["hooks"] ||= {})["PostToolUse"] ||= [])
        entries << { "matcher" => "Bash", "hooks" => [ { "type" => "command", "command" => "#{HOOK} claude", "timeout" => 60 } ] }
      end
    end

    def install_cursor
      managed(".cursor/commands/browser-pr-verification.md", render("cursor_command.md"))
      merge_json(".cursor/hooks.json") do |settings|
        settings["version"] ||= 1
        ((settings["hooks"] ||= {})["afterShellExecution"] ||= []) << { "command" => "#{HOOK} cursor" }
      end
    end

    # Codex runs a project hook only after the person trusts it in /hooks, so the AGENTS.md section also
    # tells the agent to publish after it opens the PR.
    def install_codex
      merge_json(".codex/hooks.json") do |settings|
        entries = ((settings["hooks"] ||= {})["PostToolUse"] ||= [])
        entries << { "matcher" => "^Bash$", "hooks" => [ { "type" => "command", "command" => "#{HOOK} codex", "timeout" => 60 } ] }
      end
      path = "AGENTS.md"
      current = exist?(path) ? File.read(File.join(@root, path)) : nil
      block = render("agents_block.md")
      updated = current.to_s.match?(BLOCK) ? current.sub(BLOCK) { block } : [ current.to_s.rstrip, block ].reject(&:empty?).join("\n\n")
      write(path, updated.end_with?("\n") ? updated : "#{updated}\n", current)
    end

    def render(name)
      ERB.new(File.read(File.join(__dir__, "templates", "#{name}.erb")), trim_mode: "-").result(binding)
    end

    def create_only(path, content)
      return @log.puts("  exists    #{path}") if exist?(path)

      write(path, content, nil)
    end

    # A file this gem wrote before is updated; a file someone else wrote is left alone without --force.
    def managed(path, content)
      current = exist?(path) ? File.read(File.join(@root, path)) : nil
      return @log.puts("  skipped   #{path} (not written by browser_review_gate; use --force to replace)") if current && !current.include?(MANAGED) && !@force

      write(path, content, current)
    end

    # Adds the hook entry unless the file already runs the hook.
    def merge_json(path)
      current = exist?(path) ? File.read(File.join(@root, path)) : nil
      return @log.puts("  unchanged #{path}") if current&.include?(HOOK)

      settings = current ? JSON.parse(current) : {}
      yield settings
      write(path, "#{JSON.pretty_generate(settings)}\n", current)
    end

    def write(path, content, current)
      return @log.puts("  unchanged #{path}") if current == content

      @log.puts "  #{current ? "updated  " : "created  "} #{path}"
      return if @dry_run

      full_path = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full_path))
      File.write(full_path, content)
    end

    def next_steps
      <<~TEXT
        Next:
          1. Add a CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY secret to the repository.
          2. Fill start_command, url and sign_in in #{Config::PATH}.
          3. Commit and merge to the default branch: the workflow runs from there.
      TEXT
    end
  end
end
