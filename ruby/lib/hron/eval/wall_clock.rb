# frozen_string_literal: true

require "date"
require "time"

module Hron
  class Evaluator
    # A wall time a fall-back repeats takes its first pass
    # (spec/README.md, "DST fall-back (ambiguous times)").
    module WallClock
      DAY_SECONDS = 86_400
      MINUTES_PER_HOUR = 60

      module_function

      # A wall time in a spring-forward gap shifts forward by the gap's length (spec/README.md,
      # "DST spring-forward (gaps)"). A Time carries no zone, so this also returns the date it
      # lands on.
      def fixed_time_on(date, time, zone)
        wall = wall_time(date, time.hour, time.minute)
        instant = first_pass(wall, zone) { nil }
        return instant, date if instant

        # Read with the offset in force before the gap, a wall time in it lands past it, where
        # the offset after the gap reads it.
        transition = gap_transition(wall, zone)
        instant = wall - transition.previous_offset.utc_total_offset
        local = instant + transition.offset.utc_total_offset
        [instant, Date.new(local.year, local.month, local.day, Date::GREGORIAN)]
      end

      # A slot in a spring-forward gap has no instant (spec/README.md, "Interval slots in a
      # spring-forward gap"); its key is the instant the gap ends, so keys never decrease in
      # wall-clock order and one binary search finds the slots on either side of an instant.
      # A Struct, as a binary search makes several for every date.
      Slot = Struct.new(:key, :instant)

      def slot_on(date, minute, zone)
        wall = wall_time(date, *minute.divmod(MINUTES_PER_HOUR))
        instant = first_pass(wall, zone) { nil }
        Slot.new(instant || gap_transition(wall, zone).at.to_time, instant)
      end

      def minute_of_day(time)
        (time.hour * MINUTES_PER_HOUR) + time.minute
      end

      def first_pass(wall, zone)
        offset = zone.periods_for_local(wall).first&.offset&.utc_total_offset
        offset ? wall - offset : yield(wall)
      end

      # The wall time as a UTC Time, so the system time zone never interferes.
      def wall_time(date, hour, minute)
        Time.utc(date.year, date.month, date.day, hour, minute)
      end

      def gap_transition(wall, zone)
        zone.transitions_up_to(wall + DAY_SECONDS, wall - DAY_SECONDS).rfind do |transition|
          transition.at.to_time + transition.previous_offset.utc_total_offset <= wall
        end
      end
    end
  end
end
