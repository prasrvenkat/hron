# frozen_string_literal: true

require "date"
require "time"

module Hron
  class Evaluator
    # Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its
    # first pass (spec/README.md, "DST fall-back (ambiguous times)").
    module WallClock
      DAY_SECONDS = 86_400
      MINUTES_PER_HOUR = 60

      module_function

      # The instant time names on date, shifted forward by the gap's length when it falls
      # in a spring-forward gap (spec/README.md, "DST spring-forward (gaps)"), and the date
      # it lands on. A Time carries no zone, so the date comes from here: only a shifted time
      # can land on a date other than its own.
      def fixed_time_on(date, time, zone)
        wall = wall_time(date, time.hour, time.minute)
        instant = first_pass(wall, zone) { nil }
        return instant, date if instant

        # Read with the offset in force before the gap, a wall time in it lands past it.
        instant = wall - gap_transition(wall, zone).previous_offset.utc_total_offset
        local = instant + zone.period_for_utc(instant).utc_total_offset
        [instant, Date.new(local.year, local.month, local.day, Date::GREGORIAN)]
      end

      # An interval slot on a date: where it sits in time, and its instant unless a
      # spring-forward gap skips it (spec/README.md, "Interval slots in a spring-forward gap").
      # A skipped slot sits at the instant its gap ends, so keys never decrease in wall-clock
      # order and one binary search finds the slots on either side of an instant. A Struct, as
      # a binary search makes several for every date.
      Slot = Struct.new(:key, :instant)

      # The slot minute minutes after midnight on date.
      def slot_on(date, minute, zone)
        wall = wall_time(date, *minute.divmod(MINUTES_PER_HOUR))
        instant = first_pass(wall, zone) { nil }
        Slot.new(instant || gap_transition(wall, zone).at.to_time, instant)
      end

      def minute_of_day(time)
        (time.hour * MINUTES_PER_HOUR) + time.minute
      end

      # The instant of the wall time's first pass, or the block's value for the wall time
      # when it falls in a gap.
      def first_pass(wall, zone)
        offset = zone.periods_for_local(wall).first&.offset&.utc_total_offset
        offset ? wall - offset : yield(wall)
      end

      # The wall time as a UTC Time, so the system time zone never interferes.
      def wall_time(date, hour, minute)
        Time.utc(date.year, date.month, date.day, hour, minute)
      end

      # The spring-forward transition whose gap contains the wall time.
      def gap_transition(wall, zone)
        zone.transitions_up_to(wall + DAY_SECONDS, wall - DAY_SECONDS).rfind do |transition|
          transition.at.to_time + transition.previous_offset.utc_total_offset <= wall
        end
      end
    end
  end
end
