module BrowserReviewGate
  # Who waived browser verification on a PR. A waiver counts only from someone other than the author,
  # unless the project allows otherwise.
  class Waiver
    def initialize(github:, config:)
      @github = github
      @config = config
    end

    def by(number, pull_request)
      return unless pull_request.fetch("labels").any? { |label| label["name"] == @config.waiver_label }

      actor = @github.label_actor(number, @config.waiver_label)
      actor if actor && (@config.waiver_by_author || actor != pull_request.dig("user", "login"))
    end
  end
end
