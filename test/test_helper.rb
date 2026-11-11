$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "browser_review_gate"
require "minitest/autorun"
require "json"
require "fileutils"
require "stringio"
require "tmpdir"

module BrowserReviewGate
  HEAD = "a" * 40
  OLD = "b" * 40

  # A pull request held in memory. Records every write the code under test makes.
  class FakeGitHub
    attr_reader :writes, :comments_list, :labels, :statuses, :reviewers, :reviews_list
    attr_accessor :branch_pr

    def initialize(head: HEAD, labels: [], comments: [], files: nil, reviewers: [], teams: [], author: "dev-user",
      branch: "feature/thing", login: "dev-user", label_actors: {}, commit_author: nil, writers: [ "dev-user" ], commits: [ OLD, HEAD ])
      @commits = commits
      @writers = writers
      @label_actors = label_actors
      @commit_author = commit_author
      @statuses = []
      @head = head
      @labels = labels.dup
      @comments_list = comments.dup
      @files = files || [ { "filename" => "app/views/home/show.html.erb", "status" => "modified", "patch" => "+<h1>Hello</h1>" } ]
      @reviewers = reviewers.dup
      @teams = teams.dup
      @author = author
      @branch = branch
      @login = login
      @branch_pr = 123
      @writes = []
      @reviews_list = []
      @next_id = 100
    end

    def repository = "example/project"
    def login = @login
    def files(_number) = @files
    def comments(_number) = @comments_list
    def reviews(_number) = @reviews_list
    def pull_request_commits(_number) = @commits
    attr_writer :changed_since

    # Files changed from a run's commit to the head, as GitHub's compare would list them.
    def changed_files_between(base, _head) = (@changed_since || {}).fetch(base, [])

    def trusted_comments(_number)
      @comments_list.reject { |comment| comment["body"].to_s.match?(Report::MARKER) && !@writers.include?(comment.dig("user", "login")) }
    end
    def pull_request_number_for_branch = @branch_pr

    def pull_request(_number)
      { "title" => "Change the home page", "user" => { "login" => @author },
        "head" => { "sha" => @head, "ref" => @branch }, "labels" => @labels.map { |name| { "name" => name } },
        "requested_reviewers" => @reviewers.map { |name| { "login" => name } },
        "requested_teams" => @teams.map { |slug| { "slug" => slug } } }
    end

    # Comments written during a test come from the workflow's bot, as they do in CI.
    def create_comment(_number, body)
      @writes << [ :create_comment, body ]
      @comments_list << { "id" => (@next_id += 1), "body" => body, "user" => { "login" => @comment_author || @login } }
    end

    def comment_as(login)
      @comment_author = login
      self
    end

    def label_actor(_number, label) = @label_actors[label]
    def commit_author(_sha) = @commit_author

    def delete_comment(id)
      @writes << [ :delete_comment, id ]
      @comments_list.reject! { |comment| comment["id"] == id }
    end
    def set_status(_sha, state:, description:, context:) = @statuses << [ state, description ]

    def request_reviewers(_number, reviewers:, team_reviewers:)
      @writes << [ :request_reviewers, reviewers, team_reviewers ]
      @reviewers |= reviewers
      @teams |= team_reviewers
    end

    def update_comment(id, body)
      @writes << [ :update_comment, id, body ]
      @comments_list.find { |comment| comment["id"] == id }["body"] = body
    end

    def add_label(_number, label)
      @writes << [ :add_label, label ]
      @labels << label
    end

    def remove_label(_number, label)
      @writes << [ :remove_label, label ]
      @labels.delete(label)
    end

    def remove_reviewers(_number, reviewers:, team_reviewers:)
      @writes << [ :remove_reviewers, reviewers, team_reviewers ]
      @reviewers -= reviewers
      @teams -= team_reviewers
    end

    def dispatch_workflow(workflow, number) = @writes << [ :dispatch, workflow, number ]
  end

  class FakeModel
    attr_reader :requests

    def initialize(answer)
      @answer = answer
      @requests = []
    end

    def complete(system:, user:, schema:)
      @requests << { system: system, user: user, schema: schema }
      @answer
    end
  end

  # git answers for a checkout at HEAD with a clean worktree.
  class FakeShell
    attr_reader :saved_path

    def initialize(head: HEAD, status: "", changed: [])
      @head = head
      @status = status
      @changed = changed
      @saved_path = File.join(Dir.mktmpdir, "browser-verification", "#{head}.json")
    end

    def call(*argv, stdin_data: nil)
      case argv
      when [ "git", "rev-parse", "HEAD" ] then @head
      when [ "git", "status", "--porcelain" ] then @status
      when [ "git", "rev-parse", "--git-path", "browser-verification/#{@head}.json" ] then @saved_path
      when [ "git", "rev-parse", "--git-path", "browser-verification" ] then File.dirname(@saved_path)
      when [ "git", "rev-parse", "--git-path", "browser-verification/evidence" ] then File.join(File.dirname(@saved_path), "evidence")
      when [ "git", "diff", "--name-only", "origin/HEAD...HEAD" ] then raise Error, "unknown revision"
      when [ "git", "diff", "--name-only", "origin/main...HEAD" ] then @changed.join("\n")
      else raise "Unexpected command: #{argv.inspect}"
      end
    end
  end

  # Answers the commands `doctor` runs, as a signed-in gh in a repository would.
  class DoctorShell
    def initialize(gh: true, push: "true", secrets: "", protection: nil, labels: [ "browser-verified", "browser-verification-waived" ])
      @labels = labels
      @gh = gh
      @push = push
      @secrets = secrets
      @protection = protection
    end

    def call(*argv, stdin_data: nil)
      case argv
      in [ "git", "rev-parse", "--show-toplevel" ] then "/repo\n"
      in [ "git", "-C", _, "rev-parse", "HEAD" ] then respond_to?(:head) ? head : raise(Error, "no HEAD")
      in [ "gh", "--version" ] | [ "gh", "auth", "status" ] then @gh ? "ok" : raise(Error, "gh is not installed")
      in [ "gh", "api", path, "--jq", ".permissions.push" ] then @push
      in [ "gh", "api", path, "--jq", ".default_branch" ] then "main"
      in [ "gh", "api", path, "--jq", ".contexts[]" ] then @protection || raise(Error, "Not Found")
      in [ "gh", "secret", "list", *] then @secrets
      in [ "gh", "api", path, "--paginate", "--jq", ".[].name" ] if path.end_with?("/labels") then @labels.join("\n")
      else raise Error, "unexpected #{argv.inspect}"
      end
    end
  end

  module TestData
    def answer(overrides = {})
      data = { decision: "required", reason: "The change alters the home page.", scenarios: [ SIGN_IN ] }.merge(overrides)
      data[:scenarios] = [] if data[:decision] == "not-required"
      JSON.generate(data)
    end

    # The scenario the default report case exercises.
    SIGN_IN = { id: "BROWSER-1", name: "Sign in and land on the dashboard" }.freeze
    SETTINGS = { id: "SETTINGS-1", name: "Change a setting and see it kept" }.freeze

    def assessment_comment(decision: "required", sha: HEAD, scenarios: [ SIGN_IN ], report_seen: nil, verified: false, id: 1, login: Assessment::AUTHOR)
      body = Assessment.parse(answer(decision: decision, scenarios: scenarios), assessed_sha: sha, report_seen: report_seen)
        .markdown(verified: verified, command: "/browser-pr-verification 123")
      { "id" => id, "body" => body, "user" => { "login" => login } }
    end

    TOOL = { "name" => "Playwright MCP", "version" => "0.0.40", "capabilities" => %w[screenshots console network] }.freeze

    def report_data(overrides = {})
      { "schema_version" => 2, "tested_sha" => HEAD, "environment" => "local", "tool" => TOOL,
        "started_at" => "2026-11-11T10:00:00Z", "finished_at" => "2026-11-11T10:04:00Z", "coverage_complete" => true,
        "cases" => [ browser_case("BROWSER-1", "Sign in") ] }.merge(overrides)
    end

    def browser_case(id, name, result: "pass")
      { "id" => id, "name" => name, "result" => result, "url" => "/sign_in", "details" => "The page showed what the scenario expects." }
    end

    def report_comment(overrides = {}, id: 9, login: "dev-user")
      report = Report.new(report_data(overrides).merge("verified_by" => "dev-user"))
      { "id" => id, "body" => Markdown.signed(report.markdown), "user" => { "login" => login } }
    end

    def report_file(overrides = {})
      path = File.join(Dir.mktmpdir, "report.json")
      File.write(path, JSON.generate(report_data(overrides)))
      path
    end
  end
end
