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
      assert_nil Config.load(@root).url
      assert_includes read("docs/browser-review-gate.md"), "browser-review-gate status"
      assert_includes read(".claude/skills/browser-pr-verification/SKILL.md"), "docs/browser-review-gate.md"
      assert_includes read(".cursor/commands/browser-pr-verification.md"), "docs/browser-review-gate.md"

      settings = JSON.parse(read(".claude/settings.json"))
      assert_equal "lint", settings.dig("hooks", "Stop", 0, "hooks", 0, "command")
      assert_equal "browser-review-gate hook claude", settings.dig("hooks", "PostToolUse", 0, "hooks", 0, "command")
      assert_equal "browser-review-gate hook cursor", JSON.parse(read(".cursor/hooks.json")).dig("hooks", "afterShellExecution", 0, "command")
      assert_equal "browser-review-gate hook codex", JSON.parse(read(".codex/hooks.json")).dig("hooks", "PostToolUse", 0, "hooks", 0, "command")

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

    def test_ci_can_take_the_gem_from_a_git_repository
      installer(agents: [ "codex" ], gem_source: "git:https://git.example/tools/browser_review_gate.git#main").install

      assert_includes read(".github/workflows/browser-review-gate.yml"),
        'git clone --quiet --depth 1 --branch "main" "https://git.example/tools/browser_review_gate.git"'
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
