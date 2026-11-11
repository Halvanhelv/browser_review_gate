require "uri"
require "yaml"

module BrowserReviewGate
  # Project settings from .github/browser-review-gate.yml. Every key is optional.
  #
  # Some settings are enforced by this gem (it refuses a report or keeps review closed); others are
  # instructions the agent receives through `status` and `verify`. `ENFORCED` and `AGENT` say which.
  class Config
    PATH = ".github/browser-review-gate.yml"
    NAME_PATTERN = /\A[a-z][a-z0-9_-]{0,31}\z/
    EVIDENCE_MODES = %w[never on_failure always].freeze
    MAX_SCENARIOS = 30
    MAX_MATRIX_CASES = 24

    DEFAULTS = {
      "label" => "browser-verified",
      # A person other than the author adds this label to let review proceed without a browser run.
      "waiver_label" => "browser-verification-waived",
      "waiver_by_author" => false,
      "status_context" => "browser-verification",
      "command" => "/browser-pr-verification",
      "workflow" => "browser-review-gate.yml",
      # Who assesses a PR: claude-cli, anthropic, openai or gemini. Unset: chosen from the credentials.
      "provider" => nil,
      "model" => nil,
      "claude_command" => nil,
      "environments" => nil,
      "verification" => nil,
      "evidence" => nil,
      "scenarios" => nil,
      "gate" => nil,
      "provenance" => nil,
      "skip_authors" => [ "dependabot[bot]", "github-actions[bot]" ],
      "skip_branch_prefixes" => [],
      # A PR that only touches these paths cannot change browser behavior; no model call is made.
      "ignore_paths" => [ "docs/**", "test/**", "spec/**", "**/*.md", ".github/**" ]
    }.freeze

    SECTIONS = {
      "verification" => { "environment" => nil, "fail_on_console_errors" => false, "fail_on_network_errors" => false },
      "evidence" => { "screenshots" => "never", "trace" => "never", "console_logs" => false, "network_logs" => false,
                      "retention_days" => 14, "link_hosts" => [] },
      "scenarios" => { "max_count" => 12, "reuse_passing" => true, "mandatory" => [], "matrix" => {} },
      "gate" => { "require_evidence" => false, "block_on_failure" => true },
      # Checks a case's Playwright trace against the tested commit: off, warn (shown in the PR) or
      # require (a passing case counts only with a verified trace).
      "provenance" => { "trace" => "off", "revision_header" => "X-App-Revision", "check_pages" => true, "clock_skew_seconds" => 300 }
    }.freeze
    TRACE_MODES = %w[off warn require].freeze

    ENVIRONMENT_KEYS = %w[url healthcheck start_command sign_in].freeze
    MANDATORY_KEYS = %w[id name why paths matrix].freeze

    def self.load(root = Dir.pwd)
      path = File.join(root, PATH)
      parse(File.exist?(path) ? File.read(path) : "")
    end

    # Settings as the default branch has them, for local commands run on a PR branch: a pull request
    # must not point the agent at another URL or loosen the policy for its own run. Falls back to the
    # checkout when the default branch has no settings yet. Returns [config, source].
    def self.load_trusted(root = Dir.pwd, shell: Shell.new)
      text = shell.call("git", "-C", root, "show", "origin/HEAD:#{PATH}")
      [ parse(text), "origin/HEAD" ]
    rescue Error
      [ load(root), "working tree" ]
    end

    def self.parse(text)
      new(text.to_s.strip.empty? ? {} : YAML.safe_load(text))
    rescue Psych::Exception => error
      raise Error, "#{PATH} is not valid YAML: #{error.message}"
    end

    def initialize(data = {})
      data = {} unless data.is_a?(Hash)
      unknown = data.keys - DEFAULTS.keys
      moved = unknown & %w[url start_command sign_in]
      raise Error, "#{PATH}: #{moved.join(", ")} moved under environments.local in 0.3.0" if moved.any?
      raise Error, "#{PATH} has unknown keys: #{unknown.join(", ")}" if unknown.any?

      @data = DEFAULTS.merge(data.compact)
      @sections = SECTIONS.to_h { |name, defaults| [ name, section(name, defaults) ] }
      @environments = read_environments
      validate
    end

    (DEFAULTS.keys - %w[environments verification evidence scenarios gate provenance]).each do |key|
      define_method(key) { @data[key] }
    end

    attr_reader :environments

    def verification = @sections["verification"]
    def evidence = @sections["evidence"]
    def scenarios = @sections["scenarios"]
    def gate = @sections["gate"]
    def provenance = @sections["provenance"]

    # The environment a run uses: the one named, the configured default, or the only one there is.
    def environment(name = nil)
      name ||= verification["environment"] || (environments.size == 1 ? environments.keys.first : nil)
      return if name.nil?
      raise Error, "Unknown environment #{name.inspect}; #{PATH} defines: #{environments.keys.join(", ")}" unless environments.key?(name)

      environments.fetch(name).merge("name" => name)
    end

    def skip?(author:, branch:)
      skip_authors.include?(author) || skip_branch_prefixes.any? { |prefix| branch.to_s.start_with?(prefix) }
    end

    # "dir/**" means everything under dir; other patterns are globs where "**/" spans directories.
    def ignored?(path) = Config.match?(ignore_paths, path)

    def self.match?(patterns, path)
      patterns.any? do |pattern|
        next path.start_with?(pattern.delete_suffix("**")) if pattern.end_with?("/**")

        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
      end
    end

    # Mandatory scenarios that apply to a change touching `paths`, expanded over the matrix where asked.
    # They are added by this code, not proposed by the model, so a PR cannot talk its way out of them.
    def mandatory_scenarios(paths)
      scenarios["mandatory"].select { |entry| entry["paths"].nil? || paths.any? { |path| Config.match?(entry["paths"], path) } }
        .flat_map { |entry| expand(entry) }
    end

    # What the settings ask of a run, split by who makes sure it happens.
    def policy
      {
        "enforced" => {
          "fail_on_console_errors" => verification["fail_on_console_errors"],
          "fail_on_network_errors" => verification["fail_on_network_errors"],
          "require_evidence" => gate["require_evidence"],
          "block_on_failure" => gate["block_on_failure"],
          "reuse_passing" => scenarios["reuse_passing"],
          "max_scenarios" => scenarios["max_count"],
          "trace_check" => provenance["trace"]
        },
        "agent" => {
          "screenshots" => evidence["screenshots"],
          "trace" => provenance["trace"] == "off" ? evidence["trace"] : "always",
          "console_logs" => evidence["console_logs"], "network_logs" => evidence["network_logs"]
        }
      }
    end

    private

    def section(name, defaults)
      value = @data[name] || {}
      raise Error, "#{PATH}: #{name} must be a mapping" unless value.is_a?(Hash)

      unknown = value.keys - defaults.keys
      raise Error, "#{PATH}: #{name} has unknown keys: #{unknown.join(", ")}" if unknown.any?

      defaults.merge(value.compact)
    end

    def read_environments
      listed = @data["environments"]
      return {} unless listed
      raise Error, "#{PATH}: environments must be a mapping of names to settings" unless listed.is_a?(Hash)

      listed.to_h do |name, settings|
        raise Error, "#{PATH}: environment name #{name.inspect} must be lowercase letters, digits, - or _" unless name.is_a?(String) && NAME_PATTERN.match?(name)
        raise Error, "#{PATH}: environments.#{name} must be a mapping" unless settings.is_a?(Hash)

        unknown = settings.keys - ENVIRONMENT_KEYS
        raise Error, "#{PATH}: environments.#{name} has unknown keys: #{unknown.join(", ")}" if unknown.any?

        [ name, settings.compact ]
      end
    end

    def validate
      environments.each do |name, settings|
        url = settings["url"]
        raise Error, "#{PATH}: environments.#{name}.url must be an http(s) URL" unless url.nil? || Config.http_url?(url)

        check = settings["healthcheck"]
        unless check.nil? || (check.is_a?(String) && (check.start_with?("/") || Config.http_url?(check)))
          raise Error, "#{PATH}: environments.#{name}.healthcheck must be a path starting with / or an http(s) URL"
        end
      end
      environment # the configured default must exist
      validate_flags
      validate_evidence
      validate_provenance
      validate_scenarios
    end

    def validate_flags
      { "verification" => %w[fail_on_console_errors fail_on_network_errors], "evidence" => %w[console_logs network_logs],
        "scenarios" => %w[reuse_passing], "gate" => %w[require_evidence block_on_failure] }.each do |name, keys|
        keys.each do |key|
          raise Error, "#{PATH}: #{name}.#{key} must be true or false" unless [ true, false ].include?(@sections[name][key])
        end
      end
    end

    def validate_evidence
      %w[screenshots trace].each do |key|
        next if EVIDENCE_MODES.include?(evidence[key])

        raise Error, "#{PATH}: evidence.#{key} must be one of #{EVIDENCE_MODES.join(", ")}"
      end
      days = evidence["retention_days"]
      raise Error, "#{PATH}: evidence.retention_days must be a whole number from 1 to 365" unless days.is_a?(Integer) && days.between?(1, 365)

      hosts = evidence["link_hosts"]
      return if hosts.is_a?(Array) && hosts.all? { |host| host.is_a?(String) && host.match?(/\A[a-z0-9.-]+\z/) }

      raise Error, "#{PATH}: evidence.link_hosts must be a list of host names"
    end

    def validate_provenance
      raise Error, "#{PATH}: provenance.trace must be one of #{TRACE_MODES.join(", ")}" unless TRACE_MODES.include?(provenance["trace"])
      raise Error, "#{PATH}: provenance.revision_header must be an HTTP header name" unless provenance["revision_header"].to_s.match?(/\A[A-Za-z0-9-]{1,64}\z/)
      raise Error, "#{PATH}: provenance.check_pages must be true or false" unless [ true, false ].include?(provenance["check_pages"])

      skew = provenance["clock_skew_seconds"]
      raise Error, "#{PATH}: provenance.clock_skew_seconds must be a whole number from 0 to 3600" unless skew.is_a?(Integer) && skew.between?(0, 3600)
    end

    def validate_scenarios
      count = scenarios["max_count"]
      raise Error, "#{PATH}: scenarios.max_count must be a whole number from 1 to #{MAX_SCENARIOS}" unless count.is_a?(Integer) && count.between?(1, MAX_SCENARIOS)

      validate_matrix
      mandatory = scenarios["mandatory"]
      raise Error, "#{PATH}: scenarios.mandatory must be a list" unless mandatory.is_a?(Array)

      mandatory.each_with_index { |entry, index| validate_mandatory(entry, index + 1) }
      ids = mandatory_scenarios_all.map { |scenario| scenario["id"] }
      raise Error, "#{PATH}: scenarios.mandatory ids must be unique after the matrix is applied" unless ids.uniq.size == ids.size

      expanded = mandatory.count { |entry| entry["matrix"] } * matrix_combinations.size
      raise Error, "#{PATH}: the matrix makes #{expanded} mandatory cases; keep it at #{MAX_MATRIX_CASES} or fewer" if expanded > MAX_MATRIX_CASES
    end

    def validate_matrix
      matrix = scenarios["matrix"]
      valid = matrix.is_a?(Hash) && matrix.all? do |name, values|
        NAME_PATTERN.match?(name.to_s) && values.is_a?(Array) && values.any? && values.all? { |value| NAME_PATTERN.match?(value.to_s) }
      end
      raise Error, "#{PATH}: scenarios.matrix maps a dimension (e.g. role) to a list of short lowercase values" unless valid
    end

    def validate_mandatory(entry, position)
      raise Error, "#{PATH}: scenarios.mandatory #{position} must be a mapping" unless entry.is_a?(Hash)

      unknown = entry.keys - MANDATORY_KEYS
      raise Error, "#{PATH}: scenarios.mandatory #{position} has unknown keys: #{unknown.join(", ")}" if unknown.any?
      raise Error, "#{PATH}: scenarios.mandatory #{position} id must use letters, digits, dots, underscores or hyphens" unless entry["id"].is_a?(String) && Report::CASE_ID_PATTERN.match?(entry["id"])
      raise Error, "#{PATH}: scenarios.mandatory #{position} needs a name" unless entry["name"].is_a?(String) && !entry["name"].strip.empty?
      raise Error, "#{PATH}: scenarios.mandatory #{position} paths must be a list of globs" unless entry["paths"].nil? || (entry["paths"].is_a?(Array) && entry["paths"].all?(String))
      raise Error, "#{PATH}: scenarios.mandatory #{position} matrix must be true or false" unless [ nil, true, false ].include?(entry["matrix"])
    end

    def mandatory_scenarios_all = scenarios["mandatory"].flat_map { |entry| expand(entry) }

    # Every combination of the matrix dimensions, e.g. [{"role"=>"admin","viewport"=>"mobile"}, ...].
    def matrix_combinations
      matrix = scenarios["matrix"]
      return [ {} ] if matrix.empty?

      matrix.values.first.product(*matrix.values.drop(1)).map { |values| matrix.keys.zip(values).to_h }
    end

    def expand(entry)
      base = { "id" => entry["id"], "name" => entry["name"].split.join(" "), "priority" => "critical", "category" => "mandatory",
               "why" => entry["why"] || "Required by the project settings for the areas this change touches." }
      return [ base ] unless entry["matrix"]

      matrix_combinations.map do |combination|
        suffix = combination.values.join(".")
        details = combination.map { |dimension, value| "#{dimension} #{value}" }.join(", ")
        base.merge("id" => "#{entry["id"]}.#{suffix}", "name" => "#{base["name"]} (#{details})", "matrix" => combination)
      end
    end

    def self.http_url?(value)
      uri = URI.parse(value.to_s)
      %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && uri.userinfo.nil?
    rescue URI::InvalidURIError
      false
    end
  end
end
