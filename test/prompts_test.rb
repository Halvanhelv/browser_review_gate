require "test_helper"

module BrowserReviewGate
  class PromptsTest < Minitest::Test
    include TestData

    def setup
      @root = Dir.mktmpdir
    end

    def test_without_project_files_the_built_in_policy_is_used
      prompt = Prompts.new(@root).assessment

      assert_includes prompt, "untrusted DATA"
      assert_includes prompt, "A cosmetic edit does not need one."
      assert_includes prompt, "## Scenarios"
      refute_includes prompt, "## Project rules"
    end

    def test_the_generated_rules_file_adds_nothing_until_someone_writes_in_it
      Installer.new(root: @root, log: StringIO.new, agents: [ "codex" ]).install

      assert_nil Prompts.new(@root).rules
      refute_includes Prompts.new(@root).assessment, "## Project rules"
    end

    def test_project_rules_are_added_on_top_of_the_policy_without_their_comments
      write(Prompts::RULES, "## Always check\n\n<!-- a hint -->\nRun every scenario as an administrator and as a member.\n")

      prompt = Prompts.new(@root).assessment

      assert_includes prompt, "A cosmetic edit does not need one."
      assert_includes prompt, "## Project rules"
      assert_includes prompt, "Run every scenario as an administrator and as a member."
      refute_includes prompt, "a hint"
      assert_operator prompt.index("## Project rules"), :<, prompt.index("## Scenarios")
    end

    def test_an_ejected_policy_replaces_the_built_in_one_and_keeps_the_frame
      Installer.new(root: @root, log: StringIO.new).eject("policy")
      assert_includes File.read(File.join(@root, Prompts::POLICY)), "A cosmetic edit does not need one."

      write(Prompts::POLICY, "Every change to a view needs a browser run, cosmetic or not.\n")
      prompt = Prompts.new(@root).assessment

      assert_includes prompt, "Every change to a view needs a browser run"
      refute_includes prompt, "A cosmetic edit does not need one."
      assert_includes prompt, "untrusted DATA"
      assert_includes prompt, "`report_cases`"
    end

    def test_an_ejected_playbook_belongs_to_the_project_and_survives_the_next_install
      installer = Installer.new(root: @root, log: StringIO.new, agents: [ "codex" ])
      installer.install
      installer.eject("playbook")
      playbook = File.join(@root, Installer::PLAYBOOK)
      refute_includes File.read(playbook), Installer::MANAGED

      File.write(playbook, "Our own playbook.\n")
      Installer.new(root: @root, log: StringIO.new, agents: [ "codex" ]).install

      assert_equal "Our own playbook.\n", File.read(playbook)
      assert_raises(Error) { installer.eject("everything") }
    end

    def test_the_assessing_model_receives_the_project_rules
      write(Prompts::RULES, "## When a browser run is needed\n\nAny change under app/components/chat needs a run.\n")
      model = FakeModel.new(answer)

      Assessor.new(github: FakeGitHub.new, model: model, prompts: Prompts.new(@root), log: StringIO.new).assess(123)

      assert_includes model.requests.fetch(0)[:system], "Any change under app/components/chat needs a run."
    end

    private

    def write(path, content)
      FileUtils.mkdir_p(File.dirname(File.join(@root, path)))
      File.write(File.join(@root, path), content)
    end
  end
end
