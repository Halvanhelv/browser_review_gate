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
    attr_reader :writes, :comments_list, :labels
    attr_accessor :branch_pr

    def initialize(head: HEAD, labels: [], comments: [], files: nil, reviewers: [], teams: [], author: "dev-user",
      branch: "feature/thing", login: "dev-user")
      @head = head
      @labels = labels.dup
      @comments_list = comments.dup
      @files = files || [ { "filename" => "app/views/home/show.html.erb", "status" => "modified", "patch" => "+<h1>Hello</h1>" } ]
      @reviewers = reviewers
      @teams = teams
      @author = author
      @branch = branch
      @login = login
      @branch_pr = 123
      @writes = []
      @next_id = 100
    end

    def repository = "example/project"
    def login = @login
    def files(_number) = @files
    def comments(_number) = @comments_list
    def pull_request_number_for_branch = @branch_pr

    def pull_request(_number)
      { "title" => "Change the home page", "user" => { "login" => @author },
        "head" => { "sha" => @head, "ref" => @branch }, "labels" => @labels.map { |name| { "name" => name } },
        "requested_reviewers" => @reviewers.map { |name| { "login" => name } },
        "requested_teams" => @teams.map { |slug| { "slug" => slug } } }
    end

    def create_comment(_number, body)
      @writes << [ :create_comment, body ]
      @comments_list << { "id" => (@next_id += 1), "body" => body, "user" => { "login" => @login } }
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

    def initialize(head: HEAD, status: "")
      @head = head
      @status = status
      @saved_path = File.join(Dir.mktmpdir, "browser-verification", "#{head}.json")
    end

    def call(*argv, stdin_data: nil)
      case argv
      when [ "git", "rev-parse", "HEAD" ] then @head
      when [ "git", "status", "--porcelain" ] then @status
      when [ "git", "rev-parse", "--git-path", "browser-verification/#{@head}.json" ] then @saved_path
      else raise "Unexpected command: #{argv.inspect}"
      end
    end
  end

  module TestData
    def answer(overrides = {})
      JSON.generate({ decision: "required", reason: "The change alters the home page.", covered_by_report: false }.merge(overrides))
    end

    def assessment_comment(decision: "required", sha: HEAD, covered: false, verified: false, id: 1, login: Assessment::AUTHOR)
      body = Assessment.parse(answer(decision: decision, covered_by_report: covered), assessed_sha: sha)
        .markdown(verified: verified, command: "/browser-pr-verification 123")
      { "id" => id, "body" => body, "user" => { "login" => login } }
    end

    def report_data(overrides = {})
      { "tested_sha" => HEAD, "coverage_complete" => true,
        "cases" => [ { "id" => "BROWSER-1", "name" => "Sign in", "result" => "pass" } ] }.merge(overrides)
    end

    def report_comment(overrides = {}, id: 9, login: "dev-user")
      report = Report.new(report_data(overrides).merge("verified_by" => "dev-user"))
      { "id" => id, "body" => report.markdown, "user" => { "login" => login } }
    end

    def report_file(overrides = {})
      path = File.join(Dir.mktmpdir, "report.json")
      File.write(path, JSON.generate(report_data(overrides)))
      path
    end
  end
end
