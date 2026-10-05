module BrowserReviewGate
  module Markdown
    # Comment text comes from a model or a report file, so it must not start markup or ping anyone.
    # "@login " for each person, so a comment that needs them reaches their notifications. Bots and
    # anything that is not a plain login get no mention.
    def self.mention(*logins)
      people = logins.flatten.compact.uniq.select { |login| login.to_s.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/) }
      people.map { |login| "@#{login} " }.join
    end

    def self.escape(value)
      value.to_s.gsub(/[\\`*_{}\[\]()<>#+.!|@]/) { |character| "\\#{character}" }.gsub(/[\r\n]+/, " ")
    end
  end
end
