# frozen_string_literal: true

require_relative "parser"
require_relative "evaluator"
require_relative "display"
require_relative "cron"
require_relative "parts"

module Hron
  # Each method that takes a time takes a Time in any zone and reads only its instant, and
  # raises TypeError for anything else. Each Time returned is in the schedule's timezone, with
  # that TZInfo::Timezone as its zone, or in UTC when the schedule has none.
  class Schedule
    # The frozen ScheduleData this schedule was built from, with the timezone in its IANA
    # capitalization.
    attr_reader :data

    # Builds a schedule from a ScheduleData, checked by the rules parse applies. Raises HronError
    # of kind :eval for the first part that breaks one, in the order of spec/README.md,
    # "Schedules built in code", and TypeError for a part of the wrong type. Keeps a frozen
    # copy, so later changes to data's lists and strings do not change the schedule.
    def initialize(data)
      @data = Ractor.make_shareable(Parts.checked(data))
    end

    # For parse and from_cron, whose parts already keep every rule and are their own.
    def self.from_valid(data)
      allocate.tap { |schedule| schedule.instance_variable_set(:@data, Ractor.make_shareable(data)) }
    end
    private_class_method :from_valid

    # Raises HronError if the expression is invalid, and TypeError unless input is a String.
    def self.parse(input)
      require_string(input, "input")
      from_valid(Parser.parse(input))
    end

    # Converts a 5-field cron expression to a Schedule that fires at the same times. Raises
    # HronError of kind :cron when it is not valid cron or has no exact hron equivalent, and
    # TypeError unless cron_expr is a String.
    def self.from_cron(cron_expr)
      require_string(cron_expr, "cron_expr")
      from_valid(Cron.from_cron(cron_expr))
    end

    # True when parse accepts input, false when it raises HronError. Raises TypeError unless
    # input is a String.
    def self.validate(input)
      require_string(input, "input")
      Parser.parse(input)
      true
    rescue HronError
      false
    end

    # A usage error, never a HronError or false (spec/README.md, "Timestamps and counts").
    def self.require_string(value, name)
      raise TypeError, "#{name} must be a String, not #{value.class}" unless value.is_a?(String)
    end
    private_class_method :require_string

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

    # Schedules are equal when their parts are.
    def ==(other)
      other.is_a?(Schedule) && data == other.data
    end

    def eql?(other)
      other.is_a?(Schedule) && data.eql?(other.data)
    end

    def hash
      data.hash
    end

    # Returns the IANA timezone name with its canonical capitalization, or nil if none was given.
    def timezone
      @data.timezone
    end

    def expression
      @data.expression
    end

    # The except dates, in the order written; empty without an except clause.
    def except
      @data.except
    end

    # An IsoUntil or NamedUntil, or nil without an until clause.
    def until
      @data.until
    end

    # The starting date as a YYYY-MM-DD String, or nil without a starting clause.
    def starting
      @data.starting
    end

    # The during months as Symbols, in the order written; empty without a during clause.
    def during
      @data.during
    end
  end
end
