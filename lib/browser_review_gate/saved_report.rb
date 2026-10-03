require "fileutils"
require "json"

module BrowserReviewGate
  # Results of a browser run made before the PR exists, kept inside the git directory for one commit.
  # They are published once a PR for that commit is opened.
  class SavedReport
    def initialize(sha:, shell: Shell.new)
      @sha = sha
      @shell = shell
    end

    def path
      @path ||= @shell.call("git", "rev-parse", "--git-path", "browser-verification/#{@sha}.json").strip
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
