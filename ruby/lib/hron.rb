# frozen_string_literal: true

require_relative "hron/version"
require_relative "hron/error"
require_relative "hron/ast"
require_relative "hron/lexer"
require_relative "hron/parser"
require_relative "hron/evaluator"
require_relative "hron/display"
require_relative "hron/cron"
require_relative "hron/schedule"

module Hron
  class << self
    # Parses a hron expression into a Schedule. Raises HronError if it is invalid.
    def parse_schedule(input)
      Schedule.parse(input)
    end

    # Validate a hron expression without raising an error
    def validate(input)
      Schedule.validate(input)
    end

    # Converts a 5-field cron expression to a Schedule that fires at the same times. Raises
    # HronError of kind :cron when it is not valid cron or has no exact hron equivalent.
    def from_cron(cron_expr)
      Schedule.from_cron(cron_expr)
    end
  end
end
