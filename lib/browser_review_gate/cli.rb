require "json"
require "optparse"

module BrowserReviewGate
  class CLI
    USAGE = <<~TEXT
      Usage: browser-review-gate COMMAND [options]

      Set up a project
        install [--agents claude,cursor,codex] [--gem-source SOURCE] [--workflow NAME] [--force] [--dry-run]
        eject policy|playbook                     copy a built-in text into the project to rewrite it there

      For an AI coding agent, from the checkout that was tested
        status [--pr NUMBER]                      what the PR needs and what to do next, as JSON
        publish [--pr NUMBER] [--report PATH]     publish observed results (default: the saved run)
        save --report PATH                        keep results until the PR for this commit is opened
        request-assessment NUMBER                 ask CI to assess a PR that has no decision yet
        hook AGENT                                after a command: publish the saved run after `gh pr create`

      For CI
        ci NUMBER                                 assess the PR and take back premature reviewer requests

      For the team
        stats [--days N]                          what the gate did on PRs of the last N days (default 30)
    TEXT

    # `github`, `config` and `model` are replaced in tests.
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, github: nil, config: nil, model: nil)
      @argv = argv.dup
      @github = github
      @config = config
      @model = model
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
    end

    # Returns the process exit status.
    def run
      command = @argv.shift
      case command
      when "install" then install
      when "eject" then eject
      when "status" then status
      when "publish" then publish
      when "save" then save
      when "request-assessment" then request_assessment
      when "hook" then hook
      when "ci" then ci
      when "stats" then stats
      when "version", "--version", "-v" then @stdout.puts(VERSION) || 0
      else @stderr.puts(USAGE) || (command.nil? || %w[help --help -h].include?(command) ? 0 : 1)
      end
    rescue Error, OptionParser::ParseError => error
      @stderr.puts error.message
      1
    end

    private

    def config = @config ||= Config.load(root)

    # Settings and rules live at the top of the repository, wherever the command is run from.
    def root
      @root ||= Shell.new.call("git", "rev-parse", "--show-toplevel").strip
    rescue Error
      @root = Dir.pwd
    end
    def github = @github ||= GitHub.new(repository: ENV["GH_REPO"] || ENV["GITHUB_REPOSITORY"])

    def options(*flags)
      parsed = {}
      OptionParser.new do |parser|
        parser.on("--pr NUMBER", Integer) { |value| parsed[:pr] = value } if flags.include?(:pr)
        parser.on("--report PATH") { |value| parsed[:report] = value } if flags.include?(:report)
        parser.on("--days N", Integer) { |value| parsed[:days] = value } if flags.include?(:days)
        parser.on("--agents LIST", Array) { |value| parsed[:agents] = value } if flags.include?(:install)
        parser.on("--gem-source SOURCE") { |value| parsed[:gem_source] = value } if flags.include?(:install)
        parser.on("--workflow NAME") { |value| parsed[:workflow] = value } if flags.include?(:install)
        parser.on("--force") { parsed[:force] = true } if flags.include?(:install)
        parser.on("--dry-run") { parsed[:dry_run] = true } if flags.include?(:install)
      end.parse!(@argv)
      parsed
    end

    def pr_number!
      number = @argv.shift.to_s
      raise Error, "A positive PR number is required" unless /\A[1-9][0-9]*\z/.match?(number)

      number.to_i
    end

    def install
      Installer.new(root: root, log: @stdout, **options(:install)).install
      0
    end

    def eject
      Installer.new(root: root, log: @stdout).eject(@argv.shift)
      0
    end

    def status
      @stdout.puts JSON.pretty_generate(Status.new(github: github, config: config, prompts: Prompts.new(root)).to_h(options(:pr)[:pr]))
      0
    end

    def publish
      parsed = options(:pr, :report)
      if Publisher.new(github: github, number: parsed[:pr], report_path: parsed[:report], config: config).publish
        @stdout.puts "Browser verification published; human review can be requested."
        return 0
      end

      @stderr.puts "Browser results published, but some required cases still need to pass."
      1
    end

    def save
      path = Publisher.new(github: github, report_path: options(:report)[:report], config: config).save
      @stdout.puts "Browser verification saved to #{path}. It is published when the PR for this commit is opened."
      0
    end

    def request_assessment
      number = pr_number!
      github.dispatch_workflow(config.workflow, number)
      @stdout.puts "Assessment requested for PR #{number}; the decision appears in the PR within about a minute."
      0
    end

    def stats
      days = options(:days).fetch(:days, 30)
      raise Error, "--days must be a positive number" unless days.positive?

      counts = Stats.new(github: github, config: config).to_h(since: (Time.now.utc - days * 86_400).strftime("%Y-%m-%d"))
      @stdout.puts "Pull requests touched in the last #{days} days: #{counts["pull_requests"]}",
        "  assessed by the gate:           #{counts["assessed"]}",
        "  needed a browser run:           #{counts["required"]}",
        "    verified by a published run:  #{counts["verified"]}",
        "    waived:                       #{counts["waived"]}",
        "    open and still owing a run:   #{counts["owed"]}",
        "    a run found a failing case:   #{counts["found_a_failure"]}"
      0
    end

    # Version 0.1.1 installed a `--before` hook that held commands back. It is gone; a project that
    # still has the entry gets a silent no-op until the installer removes it.
    def hook
      return 0 if @argv.delete("--before")

      agent = @argv.shift
      message = Hook.new(publisher_factory: -> { Publisher.new(github: github, config: config) }).after(@stdin.read)
      output = Hook.render(message, agent)
      @stdout.puts output if output
      0
    end

    # The gate runs even when the assessment failed: an unknown decision keeps review closed.
    def ci
      number = pr_number!
      pull_request = github.pull_request(number)
      if config.skip?(author: pull_request.dig("user", "login"), branch: pull_request.dig("head", "ref"))
        @stdout.puts "PR #{number} is not gated (skipped author or branch)."
        return 0
      end

      failed = false
      begin
        model = @model || ModelClient.for(config)
        Assessor.new(github: github, model: model, config: config, prompts: Prompts.new(root), log: @stdout).assess(number, pull_request: pull_request)
      rescue Error => error
        failed = true
        # Escaped per the workflow-command spec so a message can never start a command of its own.
        message = error.message.gsub("%", "%25").gsub("\r", "%0D").gsub("\n", "%0A")
        @stdout.puts "::error title=Browser verification assessment failed::#{message}"
      end
      Gate.new(github: github, config: config, log: @stdout).enforce(number)
      failed ? 1 : 0
    end
  end
end
