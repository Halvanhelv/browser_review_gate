require "yaml"

module BrowserReviewGate
  # Project settings from .github/browser-review-gate.yml. Every key is optional.
  class Config
    PATH = ".github/browser-review-gate.yml"
    DEFAULTS = {
      "label" => "browser-verified",
      # A person other than the author adds this label to let review proceed without a browser run.
      "waiver_label" => "browser-verification-waived",
      "waiver_by_author" => false,
      "status_context" => "browser-verification",
      "command" => "/browser-pr-verification",
      "workflow" => "browser-review-gate.yml",
      "model" => nil,
      "claude_command" => nil,
      # How an agent starts and reaches the app for a browser run.
      "start_command" => nil,
      "url" => nil,
      "sign_in" => nil,
      "skip_authors" => [ "dependabot[bot]", "github-actions[bot]" ],
      "skip_branch_prefixes" => [],
      # A PR that only touches these paths cannot change browser behavior; no model call is made.
      "ignore_paths" => [ "docs/**", "test/**", "spec/**", "**/*.md", ".github/**" ]
    }.freeze

    def self.load(root = Dir.pwd)
      path = File.join(root, PATH)
      new(File.exist?(path) ? YAML.safe_load_file(path) : {})
    rescue Psych::Exception => error
      raise Error, "#{PATH} is not valid YAML: #{error.message}"
    end

    def initialize(data = {})
      data = {} unless data.is_a?(Hash)
      unknown = data.keys - DEFAULTS.keys
      raise Error, "#{PATH} has unknown keys: #{unknown.join(", ")}" if unknown.any?

      @data = DEFAULTS.merge(data.compact)
    end

    DEFAULTS.each_key { |key| define_method(key) { @data[key] } }

    def app
      { "start_command" => start_command, "url" => url, "sign_in" => sign_in }.compact
    end

    def skip?(author:, branch:)
      skip_authors.include?(author) || skip_branch_prefixes.any? { |prefix| branch.to_s.start_with?(prefix) }
    end

    # "dir/**" means everything under dir; other patterns are globs where "**/" spans directories.
    def ignored?(path)
      ignore_paths.any? do |pattern|
        next path.start_with?(pattern.delete_suffix("**")) if pattern.end_with?("/**")

        File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_DOTMATCH)
      end
    end
  end
end
