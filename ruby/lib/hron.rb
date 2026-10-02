# frozen_string_literal: true

require_relative "hron/version"
require_relative "hron/error"
require_relative "hron/ast"
require_relative "hron/lexer"
require_relative "hron/parser"
require_relative "hron/evaluator"
require_relative "hron/display"
require_relative "hron/cron"
require_relative "hron/parts"
require_relative "hron/schedule"

module Hron
  # Parser, Evaluator, Display and Cron take or return a schedule's parts without the checks
  # of Schedule.new, Parts is those checks, and Lexer gives Parser its tokens, so only code
  # inside Hron uses them (spec/README.md, "Schedules built in code").
  private_constant :Lexer, :Parser, :Evaluator, :Display, :Cron, :Parts

  class << self
    # Parses a hron expression into a Schedule. Raises HronError if it is invalid, and TypeError
    # unless input is a String.
    def parse_schedule(input)
      Schedule.parse(input)
    end

    # True when parse accepts input, false when it raises HronError. Raises TypeError unless
    # input is a String.
    def validate(input)
      Schedule.validate(input)
    end

    # Converts a 5-field cron expression to a Schedule that fires at the same times. Raises
    # HronError of kind :cron when it is not valid cron or has no exact hron equivalent, and
    # TypeError unless cron_expr is a String.
    def from_cron(cron_expr)
      Schedule.from_cron(cron_expr)
    end
  end
end
