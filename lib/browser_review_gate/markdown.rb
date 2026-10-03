module BrowserReviewGate
  module Markdown
    # Comment text comes from a model or a report file, so it must not start markup or ping anyone.
    def self.escape(value)
      value.to_s.gsub(/[\\`*_{}\[\]()<>#+.!|@]/) { |character| "\\#{character}" }.gsub(/[\r\n]+/, " ")
    end
  end
end
