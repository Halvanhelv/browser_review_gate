require_relative "browser_review_gate/version"

# Keeps human review of a pull request behind a browser run of its browser-visible changes.
#
# CI side (`browser-review-gate ci`): decide whether the PR needs a browser run, record the decision in
# one PR comment, and remove reviewer requests until a passing run is published.
# Local side (`save`, `publish`, `status`, `hook`): an AI coding agent runs the scenarios in a browser
# and publishes what it observed.
module BrowserReviewGate
  Error = Class.new(StandardError)

  # URL-safe Base64 without padding, for the data kept in PR comment markers. Uses nothing outside the
  # core, so the executable also runs from a plain copy of this directory.
  module Marker
    def self.encode(text) = [ text ].pack("m0").tr("+/", "-_").delete("=")

    def self.decode(payload)
      padded = payload.tr("-_", "+/")
      "#{padded}#{"=" * ((4 - padded.length % 4) % 4)}".unpack1("m0")
    end
  end

  autoload :Assessment, File.join(__dir__, "browser_review_gate/assessment")
  autoload :Assessor, File.join(__dir__, "browser_review_gate/assessor")
  autoload :CLI, File.join(__dir__, "browser_review_gate/cli")
  autoload :Config, File.join(__dir__, "browser_review_gate/config")
  autoload :Gate, File.join(__dir__, "browser_review_gate/gate")
  autoload :GitHub, File.join(__dir__, "browser_review_gate/github")
  autoload :Hook, File.join(__dir__, "browser_review_gate/hook")
  autoload :Installer, File.join(__dir__, "browser_review_gate/installer")
  autoload :Markdown, File.join(__dir__, "browser_review_gate/markdown")
  autoload :ModelClient, File.join(__dir__, "browser_review_gate/model_client")
  autoload :Prompts, File.join(__dir__, "browser_review_gate/prompts")
  autoload :Publisher, File.join(__dir__, "browser_review_gate/publisher")
  autoload :Report, File.join(__dir__, "browser_review_gate/report")
  autoload :SavedReport, File.join(__dir__, "browser_review_gate/saved_report")
  autoload :Shell, File.join(__dir__, "browser_review_gate/shell")
  autoload :Status, File.join(__dir__, "browser_review_gate/status")
end
