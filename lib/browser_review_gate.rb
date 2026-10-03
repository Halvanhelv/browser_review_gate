require_relative "browser_review_gate/version"

# Keeps human review of a pull request behind a browser run of its browser-visible changes.
#
# CI side (`browser-review-gate ci`): decide whether the PR needs a browser run, record the decision in
# one PR comment, and remove reviewer requests until a passing run is published.
# Local side (`save`, `publish`, `status`, `hook`): an AI coding agent runs the scenarios in a browser
# and publishes what it observed.
module BrowserReviewGate
  Error = Class.new(StandardError)

  autoload :Assessment, "browser_review_gate/assessment"
  autoload :Assessor, "browser_review_gate/assessor"
  autoload :CLI, "browser_review_gate/cli"
  autoload :Config, "browser_review_gate/config"
  autoload :Gate, "browser_review_gate/gate"
  autoload :GitHub, "browser_review_gate/github"
  autoload :Hook, "browser_review_gate/hook"
  autoload :Installer, "browser_review_gate/installer"
  autoload :Markdown, "browser_review_gate/markdown"
  autoload :ModelClient, "browser_review_gate/model_client"
  autoload :Publisher, "browser_review_gate/publisher"
  autoload :Report, "browser_review_gate/report"
  autoload :SavedReport, "browser_review_gate/saved_report"
  autoload :Shell, "browser_review_gate/shell"
  autoload :Status, "browser_review_gate/status"
end
