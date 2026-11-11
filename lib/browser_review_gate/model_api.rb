require "json"
require "net/http"
require "uri"

module BrowserReviewGate
  # One request to a model provider's HTTP API, with no tools and the answer bound to a JSON schema.
  # For projects that assess with an API key instead of the Claude Code CLI.
  class ModelApi
    PROVIDERS = {
      "anthropic" => { key: "ANTHROPIC_API_KEY", model: "claude-opus-5-5" },
      "openai" => { key: "OPENAI_API_KEY" },
      "gemini" => { key: "GEMINI_API_KEY" }
    }.freeze
    MAX_TOKENS = 16_000

    # `transport` takes the URL, the headers and the request body, and returns [HTTP status, body].
    def initialize(provider:, model: nil, transport: nil)
      settings = PROVIDERS.fetch(provider) { raise Error, "Unknown model provider #{provider.inspect} (known: #{PROVIDERS.keys.join(", ")})" }
      @provider = provider
      @key_name = settings.fetch(:key)
      @default_model = settings[:model]
      @model = model.to_s.empty? ? @default_model : model
      @transport = transport || method(:post)
      raise Error, "Set `model` in #{Config::PATH} to assess with #{provider}" unless @model
    end

    # Token counts of the last call as the provider reported them, or nil. Providers report no cost.
    attr_reader :last_usage

    # Returns the model's answer as JSON text. Raises Error when the call fails or gives no answer.
    def complete(system:, user:, schema:)
      key = ENV[@key_name].to_s
      raise Error, "The model gave no answer: #{@key_name} is not set" if key.empty?

      url, headers, body = send("#{@provider}_request", key, system, user, schema)
      status, text = @transport.call(url, headers, body)
      response = parse(text)
      @last_usage = usage(response)
      raise Error, "The model gave no answer: HTTP #{status} #{failure(response, text)}" unless status.to_i == 200

      answer = parse(send("#{@provider}_answer", response))
      return JSON.generate(answer) unless answer.empty?

      raise Error, "The model gave no answer: #{failure(response, text)}"
    end

    private

    # A request the provider's safeguards decline is retried on the provider's recommended fallback.
    # That is asked for only with the built-in model: a model the project chose may not accept it.
    def anthropic_request(key, system, user, schema)
      headers = { "x-api-key" => key, "anthropic-version" => "2023-06-01" }
      body = { model: @model, max_tokens: MAX_TOKENS, system: system, messages: [ { role: "user", content: user } ],
               output_config: { format: { type: "json_schema", schema: schema } } }
      if @model == @default_model
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        body[:fallbacks] = "default"
      end
      [ "https://api.anthropic.com/v1/messages", headers, body ]
    end

    def anthropic_answer(response)
      return if response["stop_reason"] == "refusal"

      Array(response["content"]).find { |block| block.is_a?(Hash) && block["type"] == "text" }&.fetch("text", nil)
    end

    def openai_request(key, system, user, schema)
      body = { model: @model, messages: [ { role: "system", content: system }, { role: "user", content: user } ],
               response_format: { type: "json_schema", json_schema: { name: "browser_assessment", schema: schema, strict: true } } }
      [ "https://api.openai.com/v1/chat/completions", { "Authorization" => "Bearer #{key}" }, body ]
    end

    def openai_answer(response)
      response.dig("choices", 0, "message", "content")
    end

    def gemini_request(key, system, user, schema)
      body = { systemInstruction: { parts: [ { text: system } ] }, contents: [ { role: "user", parts: [ { text: user } ] } ],
               generationConfig: { responseMimeType: "application/json", responseJsonSchema: schema } }
      [ "https://generativelanguage.googleapis.com/v1beta/models/#{@model}:generateContent", { "x-goog-api-key" => key }, body ]
    end

    def gemini_answer(response)
      Array(response.dig("candidates", 0, "content", "parts")).filter_map { |part| part["text"] if part.is_a?(Hash) }.join
    end

    def usage(response)
      input, output = case @provider
                      when "anthropic" then [ response.dig("usage", "input_tokens"), response.dig("usage", "output_tokens") ]
                      when "openai" then [ response.dig("usage", "prompt_tokens"), response.dig("usage", "completion_tokens") ]
                      else [ response.dig("usageMetadata", "promptTokenCount"), response.dig("usageMetadata", "candidatesTokenCount") ]
                      end
      return unless input.is_a?(Integer) || output.is_a?(Integer)

      { "provider" => @provider, "model" => (response["model"] || response["modelVersion"] || @model).to_s,
        "input_tokens" => input, "output_tokens" => output }.compact
    end

    def parse(text)
      data = JSON.parse(text.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    # Providers explain an error in `error.message`; a declined request has no text to return.
    def failure(response, text)
      message = response.dig("error", "message") if response["error"].is_a?(Hash)
      message ||= "the request was declined" if response["stop_reason"] == "refusal" || response.dig("choices", 0, "message", "refusal")
      (message || text.to_s.strip)[0, 300]
    end

    def post(url, headers, body)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri, headers.merge("Content-Type" => "application/json"))
      request.body = JSON.generate(body)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 300) { |http| http.request(request) }
      [ response.code, response.body ]
    rescue SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => error
      raise Error, "The model gave no answer: #{error.message}"
    end
  end
end
