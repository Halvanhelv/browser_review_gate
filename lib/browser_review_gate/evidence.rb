require "digest"
require "fileutils"
require "uri"

module BrowserReviewGate
  # Turns the evidence an agent lists in a submitted report into what is published.
  #
  # Files (screenshots, traces) are read from the directory of the report file, checked, hashed and
  # copied into the git directory; the PR gets their names, sizes and SHA-256 digests, never the
  # files. A digest shows that a file of that type existed when the run was published. It does not
  # show that a browser produced it. Console and network entries are the agent's own account; they are
  # trimmed and scrubbed of anything that looks like a credential.
  class Evidence
    MAX_FILE_BYTES = 20 * 1024 * 1024
    MAX_FILES = 10
    MAX_ENTRIES = 50
    MAX_ENTRY = 500
    KINDS = { "screenshots" => "screenshot", "trace" => "trace" }.freeze
    # Accepted files by extension, each with the bytes its content must start with.
    TYPES = {
      ".png" => [ "image/png", [ "\x89PNG\r\n\x1A\n".b ] ],
      ".jpg" => [ "image/jpeg", [ "\xFF\xD8\xFF".b ] ],
      ".jpeg" => [ "image/jpeg", [ "\xFF\xD8\xFF".b ] ],
      ".webp" => [ "image/webp", [ "RIFF".b ] ],
      ".zip" => [ "application/zip", [ "PK\x03\x04".b ] ]
    }.freeze
    TRACE_TYPES = %w[.zip].freeze
    SECRET = /
      (?<key>authorization|proxy-authorization|cookie|set-cookie|x-api-key|api[_-]?key|access[_-]?token|refresh[_-]?token|
        id[_-]?token|token|secret|password|passwd|session(?:[_-]?id)?|csrf[_-]?token|auth)
      (?<sep>["']?\s*[:=]\s*["']?)(?:bearer\s+|basic\s+)?[^\s"',;&]+
    /xi
    BEARER = /\b(bearer|basic)\s+[A-Za-z0-9._~+\/=-]{8,}/i
    JWT = /\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}/
    LONG_TOKEN = /\b[A-Za-z0-9_-]{40,}\b/

    # Masks values that look like credentials. Applied to everything an agent writes into a report.
    def self.scrub(text)
      text.to_s.gsub(SECRET) { "#{$~[:key]}#{$~[:sep]}[REDACTED]" }.gsub(BEARER) { "#{$1} [REDACTED]" }
        .gsub(JWT, "[REDACTED]").gsub(LONG_TOKEN, "[REDACTED]")
    end

    # Origin and path only: query strings and fragments carry tokens too often to publish.
    def self.safe_url(value)
      uri = URI.parse(value.to_s)
      return scrub(value.to_s.split(/[?#]/).first.to_s)[0, 300] unless uri.scheme

      port = uri.port == uri.default_port ? "" : ":#{uri.port}"
      scrub("#{uri.scheme}://#{uri.host}#{port}#{uri.path}")[0, 300]
    rescue URI::InvalidURIError
      "[unparseable URL]"
    end

    attr_reader :files

    # `base_dir` is where the report file lives; every evidence path is relative to it.
    def initialize(base_dir:, config: Config.new)
      @base_dir = base_dir && File.realpath(base_dir)
      @config = config
      @files = []
    rescue SystemCallError
      raise Error, "The report directory #{base_dir} cannot be read"
    end

    # Returns the report data with each case's evidence in its published form. Raises Error naming the
    # case and the problem when a path, file or entry is not acceptable.
    def process(data)
      return data unless data.is_a?(Hash) && data["cases"].is_a?(Array)

      data.merge("cases" => data["cases"].each_with_index.map { |test_case, index| process_case(test_case, index + 1) })
    end

    # Copies the accepted files under `dir`, by digest, so the run can be looked at later.
    def keep(dir)
      files.each do |file|
        target = File.join(dir, "#{file["sha256"]}#{File.extname(file["name"])}")
        FileUtils.mkdir_p(dir)
        FileUtils.cp(file.fetch("source"), target) unless File.exist?(target)
      end
    end

    private

    def process_case(test_case, position)
      return test_case unless test_case.is_a?(Hash) && test_case.key?("evidence")

      evidence = test_case["evidence"]
      raise Error, "case #{position} evidence must be an object" unless evidence.is_a?(Hash)

      unknown = evidence.keys - %w[screenshots trace console_errors network_errors links]
      raise Error, "case #{position} evidence has unknown keys: #{unknown.join(", ")}" if unknown.any?

      published = {}
      listed = Array(evidence["screenshots"]).map { |path| [ "screenshots", path ] }
      listed << [ "trace", evidence["trace"] ] if evidence["trace"]
      raise Error, "case #{position} evidence lists more than #{MAX_FILES} files" if listed.size > MAX_FILES

      published["files"] = listed.map { |kind, path| file(kind, path, position) } if listed.any?
      published["console_errors"] = entries(evidence["console_errors"], position, "console_errors") { |entry| Evidence.scrub(entry) } if evidence.key?("console_errors")
      published["network_errors"] = entries(evidence["network_errors"], position, "network_errors") { |entry| network(entry) } if evidence.key?("network_errors")
      published["links"] = links(evidence["links"], position) if evidence.key?("links")
      test_case.merge("evidence" => published)
    end

    def file(kind, path, position)
      raise Error, "case #{position} evidence files need a report file to be relative to" unless @base_dir
      raise Error, "case #{position} #{kind} path must be a relative path inside the report directory" unless relative?(path)

      full = File.join(@base_dir, path)
      raise Error, "case #{position} #{kind} file #{path} does not exist" unless File.exist?(full)
      raise Error, "case #{position} #{kind} file #{path} must be a regular file, not a link" if File.symlink?(full) || !File.file?(full)

      real = File.realpath(full)
      raise Error, "case #{position} #{kind} file #{path} is outside the report directory" unless real.start_with?("#{@base_dir}/")

      extension = File.extname(real).downcase
      allowed = kind == "trace" ? TRACE_TYPES : TYPES.keys - TRACE_TYPES
      raise Error, "case #{position} #{kind} file #{path} must be one of #{allowed.join(", ")}" unless allowed.include?(extension)

      bytes = File.size(real)
      raise Error, "case #{position} #{kind} file #{path} is larger than #{MAX_FILE_BYTES / 1024 / 1024} MB" if bytes > MAX_FILE_BYTES

      media_type, signatures = TYPES.fetch(extension)
      head = File.binread(real, 16).to_s
      raise Error, "case #{position} #{kind} file #{path} is not a #{media_type} file" unless signatures.any? { |signature| head.start_with?(signature) }

      entry = { "kind" => KINDS.fetch(kind), "name" => File.basename(real)[0, 100], "media_type" => media_type,
                "bytes" => bytes, "sha256" => Digest::SHA256.file(real).hexdigest }
      @files << entry.merge("source" => real)
      entry
    end

    def relative?(path)
      path.is_a?(String) && !path.empty? && path.length <= 300 && !path.start_with?("/", "~") &&
        !path.include?("\0") && !path.split(%r{[/\\]}).include?("..")
    end

    def entries(value, position, key)
      raise Error, "case #{position} evidence #{key} must be a list" unless value.is_a?(Array)
      raise Error, "case #{position} evidence #{key} has more than #{MAX_ENTRIES} entries" if value.size > MAX_ENTRIES

      value.map { |entry| yield(entry).to_s[0, MAX_ENTRY] }
    end

    # A failed request as "METHOD URL -> STATUS", with the URL reduced to origin and path.
    def network(entry)
      return Evidence.safe_url(entry) unless entry.is_a?(Hash)

      method = entry["method"].to_s.upcase[/\A[A-Z]{1,10}\z/]
      status = entry["status"].to_s[/\A\d{1,3}|\A[a-z_:]{1,40}\z/i]
      [ method, Evidence.safe_url(entry["url"]), status && "-> #{status}" ].compact.join(" ")
    end

    # Links to evidence kept elsewhere, accepted only on hosts the project listed.
    def links(value, position)
      raise Error, "case #{position} evidence links must be a list" unless value.is_a?(Array)
      raise Error, "case #{position} evidence has more than #{MAX_FILES} links" if value.size > MAX_FILES

      value.map do |link|
        uri = URI.parse(link.to_s)
        allowed = uri.scheme == "https" && uri.userinfo.nil? && @config.evidence["link_hosts"].include?(uri.host)
        raise Error, "case #{position} evidence link #{link.to_s[0, 100]} must be https on a host listed in evidence.link_hosts" unless allowed

        link.to_s[0, 300]
      rescue URI::InvalidURIError
        raise Error, "case #{position} evidence link is not a valid URL"
      end
    end
  end
end
