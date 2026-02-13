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
    # Parse a hron expression and return a Schedule
    def parse_schedule(input)
      Schedule.parse(input)
    end

    # Validate a hron expression without raising an error
    def validate(input)
      Schedule.validate(input)
    end

    # Parse from a cron expression
    def from_cron(cron_expr)
      Schedule.from_cron(cron_expr)
    end
  end
end
