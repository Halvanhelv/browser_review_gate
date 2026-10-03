require "test_helper"
require "open3"

module BrowserReviewGate
  # Drives the real executable through a whole PR, with `gh` and the model replaced by scripts.
  class IntegrationTest < Minitest::Test
    BIN = File.expand_path("support/fake_bin", __dir__)
    EXE = File.expand_path("../exe/browser-review-gate", __dir__)

    def setup
      @repo = Dir.mktmpdir
      @tmp = Dir.mktmpdir
      @state = File.join(@tmp, "state.json")
      @model_log = File.join(@tmp, "model.log")
      File.write(@model_log, "")
      write_state("open" => false, "head" => nil, "labels" => [], "reviewers" => [], "comments" => [], "files" => [], "dispatched" => [])
      git("init", "-q", "-b", "main")
      commit(".github/browser-review-gate.yml" => "claude_command: #{BIN}/fake-claude\nworkflow: gate.yml\n", "app/views/home.erb" => "<h1>Home</h1>\n")
    end

    def test_a_run_saved_before_the_pr_carries_it_through_review_and_a_later_commit_reopens_the_gate
      assert_equal "run_and_save", status.fetch("next")

      run!("save", "--report", report("BROWSER-1"))
      assert_equal "open_pull_request", status.fetch("next")
      assert_empty git("status", "--porcelain")

      # The author opens the PR; the agent's hook publishes the saved run.
      update_state("open" => true, "head" => head, "files" => [ file("app/views/home.erb") ])
      hook_output = run!("hook", "claude", stdin: JSON.generate(tool_input: { command: "gh pr create --title x" }))
      assert_includes JSON.parse(hook_output).dig("hookSpecificOutput", "additionalContext"), "published"
      assert_equal [ "browser-verified" ], state.fetch("labels")

      # CI assesses the PR and leaves the reviewer in place.
      update_state("reviewers" => [ "reviewer" ])
      run!("ci", "7", login: "github-actions[bot]")
      assert_equal [ "reviewer" ], state.fetch("reviewers")
      assert_includes state.fetch("comments").last.fetch("body"), "report covers it"
      assert_equal "nothing", status.fetch("next")

      # A new commit changes another view: the label and the reviewer request go.
      commit("app/views/settings.erb" => "<h1>Settings</h1>\n")
      update_state("head" => head, "files" => [ file("app/views/home.erb"), file("app/views/settings.erb") ])
      run!("ci", "7", login: "github-actions[bot]")
      assert_empty state.fetch("labels")
      assert_empty state.fetch("reviewers")
      assert_includes state.fetch("comments").last.fetch("body"), "Run `/browser-pr-verification 7`"
      assert_equal "run_and_publish", status.fetch("next")

      # The agent runs the new scenario and publishes; the earlier case is carried over.
      run!("publish", "--report", report("BROWSER-2"))
      assert_equal [ "browser-verified" ], state.fetch("labels")
      published = state.fetch("comments").find { |comment| comment["body"].include?("browser-verification-report:") }.fetch("body")
      assert_includes published, "BROWSER-1"
      assert_includes published, "BROWSER-2"

      update_state("reviewers" => [ "reviewer" ])
      run!("ci", "7", login: "github-actions[bot]")
      assert_equal [ "reviewer" ], state.fetch("reviewers")
    end

    def test_a_pr_that_cannot_touch_the_browser_is_cleared_without_the_model
      update_state("open" => true, "head" => head, "files" => [ file("README.md"), file("docs/setup.md") ], "reviewers" => [ "reviewer" ])

      run!("ci", "7", login: "github-actions[bot]")

      assert_equal "", File.read(@model_log)
      assert_equal [ "reviewer" ], state.fetch("reviewers")
      assert_includes state.fetch("comments").last.fetch("body"), "not needed"
    end

    def test_an_unverified_pr_loses_its_reviewer_and_the_agent_can_ask_for_an_assessment
      update_state("open" => true, "head" => head, "files" => [ file("app/views/home.erb") ], "reviewers" => [ "reviewer" ])
      assert_equal "request_assessment", status.fetch("next")

      run!("request-assessment", "7")
      assert_equal [ [ "gate.yml", "pr_number=7" ] ], state.fetch("dispatched")

      run!("ci", "7", login: "github-actions[bot]")
      assert_empty state.fetch("reviewers")
      assert_equal "called\n", File.read(@model_log)

      _output, status = run_cli("publish", "--report", report("BROWSER-1", coverage_complete: false))
      refute status.success?
      assert_empty state.fetch("labels")
      assert_includes state.fetch("comments").last.fetch("body"), "Not verified"
    end

    private

    def head = git("rev-parse", "HEAD").strip
    def state = JSON.parse(File.read(@state))
    def write_state(data) = File.write(@state, JSON.generate(data))
    def update_state(changes) = write_state(state.merge(changes))
    def file(name) = { "filename" => name, "status" => "modified", "patch" => "+changed" }
    def status = JSON.parse(run!("status"))

    def git(*argv)
      output, status = Open3.capture2e("git", "-c", "user.name=Test", "-c", "user.email=test@example.test",
        "-c", "commit.gpgsign=false", *argv, chdir: @repo)
      raise output unless status.success?

      output
    end

    def commit(files)
      files.each do |path, content|
        FileUtils.mkdir_p(File.dirname(File.join(@repo, path)))
        File.write(File.join(@repo, path), content)
      end
      git("add", "-A")
      git("commit", "-q", "-m", "change")
    end

    def report(case_id, coverage_complete: true)
      path = File.join(@tmp, "#{case_id}.json")
      File.write(path, JSON.generate(tested_sha: head, coverage_complete: coverage_complete,
        cases: [ { id: case_id, name: "Scenario #{case_id}", result: "pass" } ]))
      path
    end

    def run_cli(*argv, login: "dev-user", stdin: "")
      environment = { "PATH" => "#{BIN}:#{ENV["PATH"]}", "FAKE_GH_STATE" => @state, "FAKE_GH_LOGIN" => login,
                      "FAKE_CLAUDE_LOG" => @model_log, "GH_REPO" => "example/project" }
      # --disable-gems proves the executable runs from a plain copy, the way CI uses a vendored one.
      Open3.capture2e(environment, RbConfig.ruby, "--disable-gems", EXE, *argv, stdin_data: stdin, chdir: @repo)
    end

    def run!(*argv, **options)
      output, status = run_cli(*argv, **options)
      assert status.success?, "#{argv.join(" ")} failed: #{output}"
      output
    end
  end
end
