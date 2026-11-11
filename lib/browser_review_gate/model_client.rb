require "json"
require "open3"
require "tmpdir"

module BrowserReviewGate
  # One headless Claude Code call with every tool disabled and the answer bound to a JSON schema, so
  # the model can only answer. The GitHub token is removed from its environment.
  class ModelClient
    NPX = %w[npx --yes @anthropic-ai/claude-code@2.1.288].freeze
    CREDENTIALS = %w[CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY].freeze

    # The client the project's settings and the credentials at hand call for. The Claude Code CLI stays
    # the default; an OpenAI or Gemini key alone selects that provider's API.
    def self.for(config, environment: ENV)
      provider = config.provider || detect(config, environment)
      return new(command: config.claude_command, model: config.model) if provider == "claude-cli"

      ModelApi.new(provider: provider, model: config.model)
    end

    def self.detect(config, environment)
      set = ->(name) { !environment[name].to_s.empty? }
      return "claude-cli" if config.claude_command || CREDENTIALS.any?(&set)

      ModelApi::PROVIDERS.keys.find { |provider| set.call(ModelApi::PROVIDERS.fetch(provider).fetch(:key)) } || "claude-cli"
    end

    # `runner` takes the environment, argv and stdin, and returns [stdout, stderr, success?].
    def initialize(command: nil, model: nil, runner: nil)
      @command = command.to_s.empty? ? default_command : command.split
      @model = model
      @runner = runner || method(:run)
    end

    # Token counts and cost of the last call as the CLI reported them, or nil.
    attr_reader :last_usage

    # Returns the model's answer as JSON text. Raises Error when the call fails or gives no answer.
    def complete(system:, user:, schema:)
      argv = @command + [ "--print", "--tools", "", "--setting-sources", "", "--system-prompt", system,
                          "--json-schema", JSON.generate(schema), "--output-format", "json" ]
      argv += [ "--model", @model ] if @model
      stdout, stderr, success = @runner.call(environment, argv, user)
      result = parse(stdout)
      @last_usage = usage(result)
      answer = result["structured_output"] if success && result["is_error"] == false
      return JSON.generate(answer) if answer.is_a?(Hash)

      raise Error, "The model gave no answer: #{failure(result, stdout, stderr)}"
    end

    private

    def usage(result)
      tokens = result["usage"].is_a?(Hash) ? result["usage"] : {}
      { "provider" => "claude-cli", "model" => @model, "input_tokens" => tokens["input_tokens"],
        "output_tokens" => tokens["output_tokens"], "cost_usd" => result["total_cost_usd"] }.compact.then { |found| found.size > 1 ? found : nil }
    end

    def parse(stdout)
      result = JSON.parse(stdout.to_s)
      result.is_a?(Hash) ? result : {}
    rescue JSON::ParserError
      {}
    end

    # The CLI explains a failure in `result`; a missing credential is the usual cause in CI.
    def failure(result, stdout, stderr)
      reason = result["result"].to_s.strip
      reason = "#{stderr} #{stdout}".strip[0, 300] if reason.empty?
      missing = CREDENTIALS.all? { |name| ENV[name].to_s.empty? }
      missing ? "#{reason} (neither #{CREDENTIALS.join(" nor ")} is set)" : reason
    end

    # An installed `claude` is used as is; CI has none and fetches a pinned version on demand.
    def default_command
      installed = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "claude")) }
      installed ? [ "claude" ] : NPX
    end

    # Empty credentials are unset: the workflow passes both kinds and only one is configured.
    def environment
      unset = %w[GH_TOKEN GITHUB_TOKEN].to_h { |name| [ name, nil ] }
      CREDENTIALS.each { |name| unset[name] = nil if ENV[name].to_s.empty? }
      unset
    end

    # Runs outside the checkout so the CLI loads no project instructions or settings.
    def run(environment, argv, stdin)
      stdout, stderr, status = Open3.capture3(environment, *argv, stdin_data: stdin, chdir: Dir.tmpdir)
      [ stdout, stderr, status.success? ]
    rescue Errno::ENOENT
      raise Error, "#{argv.first} is not installed"
    end
  end
end
