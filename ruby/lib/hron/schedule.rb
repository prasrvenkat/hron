# frozen_string_literal: true

require_relative "parser"
require_relative "evaluator"
require_relative "display"
require_relative "cron"

module Hron
  # Main Schedule class - the primary public API for hron
  class Schedule
    attr_reader :data

    def initialize(data)
      @data = data
    end

    # Parse a hron expression and return a Schedule
    def self.parse(input)
      new(Hron.parse(input))
    end

    # Parse a cron expression and return a Schedule
    def self.from_cron(cron_expr)
      new(Cron.from_cron(cron_expr))
    end

    # Validate a hron expression without raising an error
    def self.validate(input)
      Hron.parse(input)
      true
    rescue HronError
      false
    end

    # Get the next occurrence from the given time
    def next_from(now)
      Evaluator.next_from(@data, now)
    end

    # Get the next N occurrences from the given time
    def next_n_from(now, n)
      Evaluator.next_n_from(@data, now, n)
    end

    # Get the most recent occurrence strictly before the given time
    def previous_from(now)
      Evaluator.previous_from(@data, now)
    end

    # Check if the schedule matches the given datetime
    def matches(dt)
      Evaluator.matches(@data, dt)
    end

    # Returns a lazy Enumerator of occurrences starting after `from`
    def occurrences(from)
      Evaluator.occurrences(@data, from)
    end

    # Returns a lazy Enumerator of occurrences where from < occurrence <= to
    def between(from, to)
      Evaluator.between(@data, from, to)
    end

    # Convert to 5-field cron expression
    def to_cron
      Cron.to_cron(@data)
    end

    # Get the canonical string representation
    def to_s
      Display.display(@data)
    end

    # Get inspect representation
    def inspect
      "Schedule(\"#{self}\")"
    end

    # Get the timezone
    def timezone
      @data.timezone
    end

    # Get the schedule expression
    def expression
      @data.expr
    end
  end
end
