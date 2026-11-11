require "test_helper"

module BrowserReviewGate
  class InstallerTest < Minitest::Test
    def setup
      @root = Dir.mktmpdir
    end

    def test_detects_the_agents_a_project_uses
      assert_equal [ "codex" ], installer.detect_agents

      touch(".claude/settings.json", "{}")
      touch(".cursorrules", "")
      touch("AGENTS.md", "# Project\n")
      assert_equal %w[claude cursor codex], installer.detect_agents
    end

    def test_installs_everything_for_every_detected_agent_in_one_run
      touch(".claude/settings.json", JSON.generate(hooks: { Stop: [ { hooks: [ { type: "command", command: "lint" } ] } ] }))
      touch(".cursor/rules/x.mdc", "")
      touch("AGENTS.md", "# Project\n\nExisting notes.\n")
      touch("bin/dev", "")

      assert_equal %w[claude cursor codex], installer.install

      workflow = read(".github/workflows/browser-review-gate.yml")
      assert_includes workflow, "gem install browser_review_gate -v #{VERSION}"
      assert_includes workflow, 'browser-review-gate ci "$PR_NUMBER"'
      assert_includes read(".github/browser-review-gate.yml"), 'start_command: "bin/dev"'
      assert_nil Config.load(@root).environment("local")["url"]
      assert_includes read("docs/browser-review-gate.md"), "browser-review-gate verify --json"
      assert_includes read(".claude/skills/browser-pr-verification/SKILL.md"), "docs/browser-review-gate.md"
      assert_includes read(".cursor/commands/browser-pr-verification.md"), "docs/browser-review-gate.md"

      settings = JSON.parse(read(".claude/settings.json"))
      assert_equal "lint", settings.dig("hooks", "Stop", 0, "hooks", 0, "command")
      assert_includes settings.dig("hooks", "PostToolUse", 0, "hooks", 0, "command"), "browser-review-gate hook claude || true"
      refute settings.fetch("hooks").key?("PreToolUse")
      cursor = JSON.parse(read(".cursor/hooks.json")).fetch("hooks")
      assert_includes cursor.dig("afterShellExecution", 0, "command"), "browser-review-gate hook cursor || true"
      refute cursor.key?("beforeShellExecution")
      assert_includes JSON.parse(read(".codex/hooks.json")).dig("hooks", "PostToolUse", 0, "hooks", 0, "command"), "hook codex || true"
      assert_includes workflow, "labeled"
      assert_includes workflow, %(fromJSON('["browser-verified","browser-verification-waived"]'))

      agents = read("AGENTS.md")
      assert_includes agents, "Existing notes."
      assert_includes agents, "browser_review_gate:start"
    end

    def test_running_again_changes_nothing_and_keeps_foreign_files
      touch("AGENTS.md", "# Project\n")
      touch("docs/browser-review-gate.md", "Our own notes.\n")
      installer(agents: %w[claude codex]).install
      before = snapshot

      log = StringIO.new
      installer(agents: %w[claude codex], log: log).install

      assert_equal before, snapshot
      assert_equal "Our own notes.\n", read("docs/browser-review-gate.md")
      assert_includes log.string, "skipped   docs/browser-review-gate.md"
      assert_equal 1, read("AGENTS.md").scan("browser_review_gate:start").size
    end

    def test_the_before_hooks_of_version_0_1_1_are_removed_and_other_hooks_are_kept
      before = "command -v browser-review-gate >/dev/null 2>&1 && browser-review-gate hook claude --before || true"
      after = "command -v browser-review-gate >/dev/null 2>&1 && browser-review-gate hook claude || true"
      touch(".claude/settings.json", JSON.generate(hooks: {
        PreToolUse: [ { matcher: "Bash", hooks: [ { type: "command", command: before } ] }, { matcher: "Write", hooks: [ { type: "command", command: "guard" } ] } ],
        PostToolUse: [ { matcher: "Bash", hooks: [ { type: "command", command: after } ] } ]
      }))
      touch(".cursor/hooks.json", JSON.generate(version: 1, hooks: {
        beforeShellExecution: [ { command: before.sub("claude", "cursor") } ], afterShellExecution: [ { command: after.sub("claude", "cursor") } ]
      }))

      installer(agents: %w[claude cursor]).install

      hooks = JSON.parse(read(".claude/settings.json")).fetch("hooks")
      assert_equal [ "guard" ], hooks.fetch("PreToolUse").map { |entry| entry.dig("hooks", 0, "command") }
      assert_equal 1, hooks.fetch("PostToolUse").size
      cursor = JSON.parse(read(".cursor/hooks.json")).fetch("hooks")
      refute cursor.key?("beforeShellExecution")
      assert_equal 1, cursor.fetch("afterShellExecution").size
    end

    def test_the_workflow_leaves_drafts_alone_until_they_are_ready_and_passes_every_provider_key
      installer.install
      workflow = read(".github/workflows/browser-review-gate.yml")

      assert_includes workflow, "ready_for_review"
      assert_includes workflow, "github.event_name == 'workflow_dispatch' || !github.event.pull_request.draft"
      %w[CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY].each { |name| assert_includes workflow, "secrets.#{name}" }
      assert Config.load(@root).provider.nil?
    end

    def test_ci_can_take_the_gem_from_a_git_repository
      installer(agents: [ "codex" ], gem_source: "git:https://git.example/tools/browser_review_gate.git#main").install

      assert_includes read(".github/workflows/browser-review-gate.yml"),
        'git clone --quiet --depth 1 --branch "main" "https://git.example/tools/browser_review_gate.git"'
    end

    def test_ci_can_use_a_copy_of_the_gem_kept_in_the_project
      installer(agents: [ "codex" ], gem_source: "path:vendor/browser_review_gate").install

      assert_includes read(".github/workflows/browser-review-gate.yml"),
        'echo "$GITHUB_WORKSPACE/vendor/browser_review_gate/exe" >> "$GITHUB_PATH"'
      assert_raises(Error) { installer(agents: [ "codex" ], gem_source: "path:../outside; rm -rf x").install }
    end

    def test_a_broken_settings_file_stops_the_install_before_anything_is_written
      touch(".claude/settings.json", "{not json")

      assert_raises(Error) { installer.install }
      assert_equal [ ".claude" ], Dir.children(@root)
    end

    def test_a_dry_run_writes_nothing_and_unknown_agents_are_refused
      installer(agents: [ "codex" ], dry_run: true).install
      assert_empty Dir.children(@root)
      assert_raises(Error) { installer(agents: [ "copilot" ]).install }
    end

    private

    def installer(log: StringIO.new, **options) = Installer.new(root: @root, log: log, **options)
    def read(path) = File.read(File.join(@root, path))
    def snapshot = Dir.glob("**/*", File::FNM_DOTMATCH, base: @root).select { |path| File.file?(File.join(@root, path)) }.to_h { |path| [ path, read(path) ] }

    def touch(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.write(File.join(@root, path), content)
    end
  end
end
