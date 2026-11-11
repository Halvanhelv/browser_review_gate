require_relative "lib/browser_review_gate/version"

Gem::Specification.new do |spec|
  spec.name = "browser_review_gate"
  spec.version = BrowserReviewGate::VERSION
  spec.authors = [ "Islam Gagiev" ]
  spec.email = [ "omniacinis@gmail.com" ]
  spec.summary = "Keeps human review of a pull request behind a browser run of its browser-visible changes."
  spec.description = "CI decides whether a pull request needs a browser run and takes back reviewer requests " \
    "until an AI coding agent (Claude Code, Cursor, Codex) has exercised the change in a browser and published " \
    "what it observed. One command sets a project up."
  spec.license = "MIT"
  spec.homepage = "https://github.com/Halvanhelv/browser_review_gate"
  spec.metadata = {
    "allowed_push_host" => "https://rubygems.org",
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/master/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "exe/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = [ "browser-review-gate" ]
  spec.require_paths = [ "lib" ]
end
