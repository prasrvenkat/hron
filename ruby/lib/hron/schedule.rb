# frozen_string_literal: true

require_relative "parser"
require_relative "evaluator"
require_relative "display"
require_relative "cron"

module Hron
  # Each method that takes a time takes a Time in any zone and reads only its instant, and
  # raises TypeError for anything else. Each Time returned is in the schedule's timezone, with
  # that TZInfo::Timezone as its zone, or in UTC when the schedule has none.
  class Schedule
    attr_reader :data

    def initialize(data)
      @data = data
    end

    # Raises HronError if the expression is invalid.
    def self.parse(input)
      new(Hron.parse(input))
    end

    # Converts a 5-field cron expression to a Schedule that fires at the same times. Raises
    # HronError of kind :cron when it is not valid cron or has no exact hron equivalent.
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

    # Returns an Array of up to n occurrences strictly after now, empty when n <= 0. Raises
    # TypeError unless n is an Integer.
    def next_n_from(now, n)
      Evaluator.next_n_from(@data, now, n)
    end

    # Returns the most recent occurrence strictly before now, or nil if there is none.
    def previous_from(now)
      Evaluator.previous_from(@data, now)
    end

    # True when the minute containing dt, on the schedule's wall clock, is an occurrence.
    def matches(dt)
      Evaluator.matches(@data, dt)
    end

    # Returns a lazy Enumerator of occurrences strictly after from. Unbounded for repeating
    # schedules unless an until clause or the end of the supported range ends them.
    def occurrences(from)
      Evaluator.occurrences(@data, from)
    end

    # Returns a lazy Enumerator of occurrences where from < occurrence <= to, empty when either
    # bound is outside the supported range.
    def between(from, to)
      Evaluator.between(@data, from, to)
    end

    # Converts to a 5-field cron expression that fires at the same times, leaving out the
    # timezone. Raises HronError of kind :cron when no cron does.
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

    # Returns the IANA timezone name with its canonical capitalization, or nil if none was given.
    def timezone
      @data.timezone
    end

    def expression
      @data.expr
    end
  end
end
