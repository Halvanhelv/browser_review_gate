require "rails/generators"
require "browser_review_gate"

module BrowserReviewGate
  module Generators
    # bin/rails generate browser_review_gate:install
    class InstallGenerator < Rails::Generators::Base
      desc "Set up the browser review gate: CI workflow, settings, playbook, and AI agent entry points."

      class_option :agents, type: :array, desc: "claude, cursor, codex (default: detected from the project)"
      class_option :gem_source, type: :string, desc: "How CI gets the gem: rubygems (default) or git:URL[#REF]"
      class_option :workflow, type: :string, desc: "Workflow file name under .github/workflows"

      def install
        BrowserReviewGate::Installer.new(
          root: destination_root, agents: options[:agents], gem_source: options[:gem_source],
          workflow: options[:workflow], force: options[:force], dry_run: options[:pretend]
        ).install
      end
    end
  end
end
