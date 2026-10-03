require "open3"

module BrowserReviewGate
  # Runs a command and returns its stdout; raises Error with stderr when it fails.
  class Shell
    def call(*argv, stdin_data: nil)
      stdout, stderr, status = Open3.capture3(*argv, stdin_data: stdin_data)
      return stdout if status.success?

      raise Error, "#{argv.join(" ")} failed: #{stderr.strip}"
    rescue Errno::ENOENT
      raise Error, "#{argv.first} is not installed"
    end
  end
end
