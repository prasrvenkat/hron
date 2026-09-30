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

    # Raises HronError if the expression is invalid.
    def self.parse(input)
      new(Hron.parse(input))
    end

    # Parses a 5-field cron expression. Raises HronError if it is invalid.
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

    # Returns the next occurrence strictly after now, or nil if there is none.
    def next_from(now)
      Evaluator.next_from(@data, now)
    end

    # Get the next N occurrences from the given time
    def next_n_from(now, n)
      Evaluator.next_n_from(@data, now, n)
    end

    # Returns the most recent occurrence strictly before now, or nil if there is none.
    def previous_from(now)
      Evaluator.previous_from(@data, now)
    end

    # Check if the schedule matches the given datetime
    def matches(dt)
      Evaluator.matches(@data, dt)
    end

    # Returns a lazy Enumerator of occurrences strictly after from. Unbounded for repeating
    # schedules unless an until clause or the end of the supported range ends them.
    def occurrences(from)
      Evaluator.occurrences(@data, from)
    end

    # Returns a lazy Enumerator of occurrences where from < occurrence <= to
    def between(from, to)
      Evaluator.between(@data, from, to)
    end

    # Converts to a 5-field cron expression. Raises HronError if there is no cron equivalent.
    def to_cron
      Cron.to_cron(@data)
    end

    # Get the canonical string representation
    def to_s
      Display.display(@data)
    end

    def inspect
      "Schedule(\"#{self}\")"
    end

    # Returns the IANA timezone name, or nil if none was given.
    def timezone
      @data.timezone
    end

    # Get the schedule expression
    def expression
      @data.expr
    end
  end
end
