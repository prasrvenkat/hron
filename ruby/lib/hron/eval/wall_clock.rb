# frozen_string_literal: true

require "time"

module Hron
  class Evaluator
    # Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its
    # first pass (spec/README.md, "DST fall-back (ambiguous times)").
    module WallClock
      DAY_SECONDS = 86_400

      module_function

      # The instant time names on date, shifted forward by the gap's length when it falls
      # in a spring-forward gap (spec/README.md, "DST spring-forward (gaps)").
      def fixed_time_on(date, time, zone)
        wall = wall_time(date, time.hour, time.minute)
        wall - (utc_offset_at(wall, zone) || offset_before_gap(wall, zone))
      end

      # The instant of the interval slot minute minutes after midnight on date, or nil when
      # that wall time falls in a spring-forward gap (spec/README.md, "Interval slots in a
      # spring-forward gap").
      def slot_on(date, minute, zone)
        wall = wall_time(date, *minute.divmod(60))
        offset = utc_offset_at(wall, zone)
        wall - offset if offset
      end

      # The slot's instant, or for a slot in a gap the gap's transition: slots in wall-clock
      # order are in this order, so it can be binary searched.
      def slot_position(date, minute, zone)
        slot_on(date, minute, zone) || gap_transition(wall_time(date, *minute.divmod(60)), zone).at.to_time
      end

      # The wall time as a UTC Time, so the system time zone never interferes.
      def wall_time(date, hour, minute)
        Time.utc(date.year, date.month, date.day, hour, minute)
      end

      # The offset of the wall time's first pass, or nil in a gap.
      def utc_offset_at(wall, zone)
        zone.periods_for_local(wall).first&.offset&.utc_total_offset
      end

      # Interpreting a gap time with the offset in force before the gap is what shifts it forward.
      def offset_before_gap(wall, zone)
        gap_transition(wall, zone).previous_offset.utc_total_offset
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
