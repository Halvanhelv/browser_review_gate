require "fileutils"
require "json"

module BrowserReviewGate
  # Results of a browser run made before the PR exists, kept inside the git directory for one commit.
  # They are published once a PR for that commit is opened.
  class SavedReport
    DIR = "browser-verification"

    # Where evidence files are kept, by digest, for runs saved or published from this checkout.
    def self.evidence_dir(shell: Shell.new)
      shell.call("git", "rev-parse", "--git-path", "#{DIR}/evidence").strip
    end

    # Removes saved runs and kept evidence older than `days`.
    def self.prune(shell: Shell.new, days: 14)
      dir = shell.call("git", "rev-parse", "--git-path", DIR).strip
      cutoff = Time.now - days * 86_400
      Dir.glob(File.join(dir, "{*.json,evidence/*}")).each { |path| FileUtils.rm_f(path) if File.file?(path) && File.mtime(path) < cutoff }
    end

    def initialize(sha:, shell: Shell.new)
      @sha = sha
      @shell = shell
    end

    def path
      @path ||= @shell.call("git", "rev-parse", "--git-path", "#{DIR}/#{@sha}.json").strip
    end

    def exist? = File.exist?(path)
    def read = JSON.parse(File.read(path))
    def delete = FileUtils.rm_f(path)

    def write(data)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(data))
    end
  end
end
