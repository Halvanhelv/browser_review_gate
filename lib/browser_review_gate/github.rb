require "json"

module BrowserReviewGate
  # Everything the gate reads from or writes to a pull request, through the `gh` CLI.
  class GitHub
    def initialize(repository: nil, shell: Shell.new)
      @repository = repository.to_s.empty? ? nil : repository
      @shell = shell
    end

    def repository
      @repository ||= JSON.parse(@shell.call("gh", "repo", "view", "--json", "nameWithOwner")).fetch("nameWithOwner")
    end

    def pull_request(number)
      api("repos/#{repository}/pulls/#{number}")
    end

    # The PR of the current branch, or nil when the branch has none.
    def pull_request_number_for_branch
      JSON.parse(@shell.call("gh", "pr", "view", "--json", "number")).fetch("number")
    rescue Error
      nil
    end

    def comments(number)
      pages("repos/#{repository}/issues/#{number}/comments")
    end

    # Comments without browser reports from people who cannot push to the repository: anyone may
    # comment on a public PR, and a report is only worth what its author is trusted with.
    def trusted_comments(number)
      comments(number).reject { |comment| comment["body"].to_s.match?(Report::MARKER) && !writer?(comment.dig("user", "login")) }
    end

    def writer?(login)
      @writers ||= {}
      return @writers[login] if @writers.key?(login)

      @writers[login] = %w[admin maintain write].include?(api("repos/#{repository}/collaborators/#{login}/permission")["permission"])
    rescue Error
      @writers[login] = false
    end

    # Pull requests touched on or after `date` (YYYY-MM-DD), open or closed.
    def pull_requests_updated_since(date)
      output = @shell.call("gh", "api", "--paginate", "--slurp", "-X", "GET", "search/issues",
        "-f", "q=repo:#{repository} is:pr updated:>=#{date}", "-f", "per_page=100")
      JSON.parse(output).flat_map { |page| page.fetch("items") }
    rescue JSON::ParserError, KeyError
      raise Error, "gh returned output that is not a pull request list"
    end

    # Full SHAs of the PR's commits, oldest first. GitHub lists at most 250.
    def pull_request_commits(number)
      pages("repos/#{repository}/pulls/#{number}/commits").map { |commit| commit.fetch("sha") }
    rescue KeyError
      raise Error, "gh returned commits without a sha for PR #{number}"
    end

    def files(number)
      pages("repos/#{repository}/pulls/#{number}/files")
    end

    def login
      @shell.call("gh", "api", "user", "--jq", ".login").strip
    end

    # The GitHub account behind a commit, or nil when the commit is not linked to one.
    def commit_author(sha)
      api("repos/#{repository}/commits/#{sha}").dig("author", "login")
    rescue Error
      nil
    end

    def delete_comment(comment_id)
      @shell.call("gh", "api", "-X", "DELETE", "repos/#{repository}/issues/comments/#{comment_id}")
    end

    def create_comment(number, body)
      api("repos/#{repository}/issues/#{number}/comments", method: "POST", input: { body: body })
    end

    def update_comment(comment_id, body)
      api("repos/#{repository}/issues/comments/#{comment_id}", method: "PATCH", input: { body: body })
    end

    # Adding a label to a PR creates the label in the repository when it does not exist yet.
    def add_label(number, label)
      api("repos/#{repository}/issues/#{number}/labels", method: "POST", input: { labels: [ label ] })
    end

    def remove_label(number, label)
      @shell.call("gh", "api", "-X", "DELETE", "repos/#{repository}/issues/#{number}/labels/#{label}")
    end

    def remove_reviewers(number, reviewers:, team_reviewers:)
      api("repos/#{repository}/pulls/#{number}/requested_reviewers", method: "DELETE",
        input: { reviewers: reviewers, team_reviewers: team_reviewers })
    end

    # Submitted reviews, oldest first.
    def reviews(number)
      pages("repos/#{repository}/pulls/#{number}/reviews")
    end

    def request_reviewers(number, reviewers:, team_reviewers:)
      api("repos/#{repository}/pulls/#{number}/requested_reviewers", method: "POST",
        input: { reviewers: reviewers, team_reviewers: team_reviewers })
    end

    # Shows the state next to the other checks of the commit.
    def set_status(sha, state:, description:, context:)
      api("repos/#{repository}/statuses/#{sha}", method: "POST",
        input: { state: state, description: description[0, 140], context: context })
    end

    # Who put the label on the PR last, or nil.
    def label_actor(number, label)
      event = pages("repos/#{repository}/issues/#{number}/events").reverse.find do |entry|
        entry["event"] == "labeled" && entry.dig("label", "name") == label
      end
      event&.dig("actor", "login")
    end

    def dispatch_workflow(workflow, number)
      @shell.call("gh", "workflow", "run", workflow, "-f", "pr_number=#{number}")
    end

    private

    def api(path, method: "GET", input: nil)
      argv = [ "gh", "api", "-X", method, path ]
      argv += [ "--input", "-" ] if input
      output = @shell.call(*argv, stdin_data: input && JSON.generate(input))
      output.strip.empty? ? {} : JSON.parse(output)
    rescue JSON::ParserError
      raise Error, "gh returned output that is not JSON for #{path}"
    end

    def pages(path)
      JSON.parse(@shell.call("gh", "api", "--paginate", "--slurp", "#{path}?per_page=100")).flatten(1)
    rescue JSON::ParserError
      raise Error, "gh returned output that is not JSON for #{path}"
    end
  end
end
