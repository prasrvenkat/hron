# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"
require_relative "ast"
require_relative "error"

module Hron
  EPOCH_DATE = Date.new(1970, 1, 1)
  EPOCH_MONDAY = Date.new(1970, 1, 5)

  # Timezone resolution
  module TzResolver
    def self.resolve(tz_name)
      if tz_name && !tz_name.empty?
        TZInfo::Timezone.get(tz_name)
      else
        # Default to UTC for deterministic, portable behavior
        TZInfo::Timezone.get("UTC")
      end
    end
  end

  # Evaluator helpers
  module EvalHelpers
    def self.at_time_on_date(d, tod, tz)
      # Create local time representation (using UTC to avoid system TZ interference)
      local_time = Time.utc(d.year, d.month, d.day, tod.hour, tod.minute, 0)

      # Get periods for this local time
      periods = tz.periods_for_local(local_time)

      case periods.length
      when 0
        # Time doesn't exist (spring forward gap)
        # Push the time forward past the gap (like "compatible" disambiguation)
        # For example: 02:30 during DST spring forward -> 03:30

        # Find the transition on this date
        day_start = Time.utc(d.year, d.month, d.day, 0, 0, 0)
        day_end = Time.utc(d.year, d.month, d.day, 23, 59, 59)
        transitions = tz.transitions_up_to(day_end, day_start)

        if transitions.any?
          # Find the spring-forward transition (where offset increases / DST starts)
          transition = transitions.find { |t| t.offset.dst? }
          if transition
            # The transition time is when the gap starts
            # We need to push the requested time forward by the gap size
            prev_offset = transition.previous_offset.utc_total_offset
            new_offset = transition.offset.utc_total_offset
            gap_seconds = new_offset - prev_offset # Positive for spring forward

            # Push the local time forward by the gap amount
            # E.g., 02:30 + 1 hour = 03:30 local
            pushed_local = local_time + gap_seconds

            # Convert the pushed local time to UTC using the new offset
            # E.g., 03:30 local EDT (-4h) -> 07:30 UTC
            return pushed_local - new_offset
          end
        end

        # Fallback: try to construct the time and let TZInfo handle it
        # This shouldn't normally be reached
        begin
          tz.local_to_utc(local_time)
        rescue TZInfo::AmbiguousTime, TZInfo::PeriodNotFound
          nil
        end
      when 1
        # Unambiguous time - straightforward conversion
        period = periods[0]
        utc_offset = period.offset.utc_total_offset
        local_time - utc_offset
      when 2
        # Ambiguous time (fall back) - use first occurrence (pre-transition)
        # Period 0 is the earlier offset (e.g., EDT -04:00 before fall back)
        period = periods[0]
        utc_offset = period.offset.utc_total_offset
        local_time - utc_offset
      end
    end

    def self.matches_day_filter(d, filter)
      dow = d.cwday # Monday=1 ... Sunday=7
      case filter
      when DayFilterEvery
        true
      when DayFilterWeekday
        dow.between?(1, 5)
      when DayFilterWeekend
        [6, 7].include?(dow)
      when DayFilterDays
        filter.days.any? { |wd| Weekday.number(wd) == dow }
      else
        false
      end
    end

    def self.last_day_of_month(year, month)
      Date.new(year, month, -1)
    end

    def self.last_weekday_of_month(year, month)
      d = last_day_of_month(year, month)
      d -= 1 while d.cwday >= 6
      d
    end

    # Get the nearest weekday to a given day in a month.
    # - direction=nil: standard cron W behavior (never crosses month boundary)
    # - direction=NearestDirection::NEXT: always prefer following weekday (can cross to next month)
    # - direction=NearestDirection::PREVIOUS: always prefer preceding weekday (can cross to prev month)
    # Returns nil if the target_day doesn't exist in the month (e.g., day 31 in February).
    def self.nearest_weekday(year, month, target_day, direction)
      last = last_day_of_month(year, month)
      last_day_num = last.day

      # If target day doesn't exist in this month, return nil (skip this month)
      return nil if target_day > last_day_num

      date = Date.new(year, month, target_day)
      dow = date.cwday # Monday=1 ... Sunday=7

      # Already a weekday (Mon-Fri = 1-5)
      return date if dow.between?(1, 5)

      case direction
      when nil
        # Standard cron W behavior: never cross month boundary
        if dow == 6 && target_day == 1
          # Saturday at 1st: can't go to previous month, use Monday (day 3)
          date + 2
        elsif dow == 6
          # Saturday: Friday
          date - 1
        elsif target_day >= last_day_num
          # Sunday at end of month: can't go to next month, use Friday
          date - 2
        else
          # Sunday: Monday
          date + 1
        end

      when NearestDirection::NEXT
        # Always prefer following weekday (can cross month)
        if dow == 6 # Saturday -> Monday
          date + 2
        else # Sunday -> Monday
          date + 1
        end

      when NearestDirection::PREVIOUS
        # Always prefer preceding weekday (can cross month if day==1)
        if dow == 6 # Saturday -> Friday
          date - 1
        else # Sunday -> Friday (go back 2 days)
          date - 2
        end
      end
    end

    def self.nth_weekday_of_month(year, month, weekday, n)
      target_dow = Weekday.number(weekday)
      d = Date.new(year, month, 1)
      d += 1 while d.cwday != target_dow
      (n - 1).times { d += 7 }
      return nil if d.month != month

      d
    end

    def self.last_weekday_in_month(year, month, weekday)
      target_dow = Weekday.number(weekday)
      d = last_day_of_month(year, month)
      d -= 1 while d.cwday != target_dow
      d
    end

    def self.weeks_between(a, b)
      (b - a).to_i / 7
    end

    def self.days_between(a, b)
      (b - a).to_i
    end

    def self.months_between_ym(a, b)
      (b.year * 12) + b.month - ((a.year * 12) + a.month)
    end

    def self.is_excepted(d, exceptions)
      exceptions.any? do |exc|
        case exc
        when NamedException
          d.month == MonthName.number(exc.month) && d.day == exc.day
        when IsoException
          d == Date.parse(exc.date)
        else
          false
        end
      end
    end

    def self.matches_during(d, during)
      return true if during.empty?

      during.any? { |mn| MonthName.number(mn) == d.month }
    end

    def self.next_during_month(d, during)
      months = during.map { |mn| MonthName.number(mn) }.sort

      months.each do |m|
        return Date.new(d.year, m, 1) if m > d.month
      end

      # Wrap to first month of next year
      Date.new(d.year + 1, months[0], 1)
    end

    def self.resolve_until(until_spec, now)
      case until_spec
      when IsoUntil
        Date.parse(until_spec.date)
      when NamedUntil
        year = now.year
        [year, year + 1].each do |y|
          d = Date.new(y, MonthName.number(until_spec.month), until_spec.day)
          return d if d >= now.to_date
        rescue ArgumentError
          next
        end
        Date.new(year + 1, MonthName.number(until_spec.month), until_spec.day)
      end
    end

    def self.earliest_future_at_times(d, times, tz, now)
      best = nil
      times.each do |tod|
        candidate = at_time_on_date(d, tod, tz)
        next unless candidate

        best = candidate if candidate > now && (best.nil? || candidate < best)
      end
      best
    end
  end

  # Main evaluator class
  class Evaluator
    def self.next_from(schedule, now)
      tz = TzResolver.resolve(schedule.timezone)
      until_date = schedule.until ? EvalHelpers.resolve_until(schedule.until, now) : nil
      has_exceptions = !schedule.except.empty?
      has_during = !schedule.during.empty?

      # Check if expression is NearestWeekday with direction (can cross month boundaries)
      handles_during_internally = schedule.expr.is_a?(MonthRepeat) &&
        schedule.expr.target.is_a?(NearestWeekdayTarget) &&
        !schedule.expr.target.direction.nil?

      current = now
      1000.times do
        candidate = next_expr(schedule.expr, tz, schedule.anchor, current, schedule.during)
        return nil unless candidate

        c_date = candidate.to_date

        # Apply until filter
        return nil if until_date && c_date > until_date

        # Apply during filter
        # Skip this check for expressions that handle during internally (NearestWeekday with direction)
        if has_during && !handles_during_internally && !EvalHelpers.matches_during(c_date, schedule.during)
          skip_to = EvalHelpers.next_during_month(c_date, schedule.during)
          midnight = EvalHelpers.at_time_on_date(skip_to, TimeOfDay.new(0, 0), tz)
          current = midnight - 1
          next
        end

        # Apply except filter
        if has_exceptions && EvalHelpers.is_excepted(c_date, schedule.except)
          next_day = c_date + 1
          midnight = EvalHelpers.at_time_on_date(next_day, TimeOfDay.new(0, 0), tz)
          current = midnight - 1
          next
        end

        return candidate
      end

      nil
    end

    def self.next_n_from(schedule, now, n)
      results = []
      current = now
      n.times do
        nxt = next_from(schedule, current)
        break unless nxt

        results << nxt
        current = nxt + 60 # Add 1 minute
      end
      results
    end

    def self.matches(schedule, dt)
      tz = TzResolver.resolve(schedule.timezone)
      # Convert to local time in the target timezone
      dt_local = tz.utc_to_local(dt.utc)
      d = dt_local.to_date

      return false if !schedule.during.empty? && !EvalHelpers.matches_during(d, schedule.during)
      return false if EvalHelpers.is_excepted(d, schedule.except)

      if schedule.until
        until_date = EvalHelpers.resolve_until(schedule.until, dt)
        return false if d > until_date
      end

      matches_expr(schedule.expr, schedule.anchor, d, dt_local, tz)
    end

    def self.next_expr(expr, tz, anchor, now, during = [])
      case expr
      when DayRepeat
        next_day_repeat(expr.interval, expr.days, expr.times, tz, anchor, now)
      when IntervalRepeat
        next_interval_repeat(expr.interval, expr.unit, expr.from_time, expr.to_time, expr.day_filter, tz, now)
      when WeekRepeat
        next_week_repeat(expr.interval, expr.days, expr.times, tz, anchor, now)
      when MonthRepeat
        next_month_repeat(expr.interval, expr.target, expr.times, tz, anchor, now, during)
      when OrdinalRepeat
        next_ordinal_repeat(expr.interval, expr.ordinal, expr.day, expr.times, tz, anchor, now)
      when SingleDateExpr
        next_single_date(expr.date, expr.times, tz, now)
      when YearRepeat
        next_year_repeat(expr.interval, expr.target, expr.times, tz, anchor, now)
      end
    end

    def self.matches_expr(expr, anchor, d, dt, tz)
      time_matches = ->(times) { time_matches_with_dst(times, d, dt, tz) }

      case expr
      when DayRepeat
        return false unless EvalHelpers.matches_day_filter(d, expr.days)
        return false unless time_matches.call(expr.times)

        if expr.interval > 1
          anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
          day_offset = EvalHelpers.days_between(anchor_date, d)
          return day_offset >= 0 && (day_offset % expr.interval).zero?
        end
        true

      when IntervalRepeat
        return false if expr.day_filter && !EvalHelpers.matches_day_filter(d, expr.day_filter)

        from_minutes = (expr.from_time.hour * 60) + expr.from_time.minute
        to_minutes = (expr.to_time.hour * 60) + expr.to_time.minute
        current_minutes = (dt.hour * 60) + dt.min
        return false if current_minutes < from_minutes || current_minutes > to_minutes

        diff = current_minutes - from_minutes
        step = (expr.unit == IntervalUnit::MIN) ? expr.interval : expr.interval * 60
        diff >= 0 && (diff % step).zero?

      when WeekRepeat
        dow = d.cwday
        return false unless expr.days.any? { |wd| Weekday.number(wd) == dow }
        return false unless time_matches.call(expr.times)

        anchor_date = anchor ? Date.parse(anchor) : EPOCH_MONDAY
        weeks = EvalHelpers.weeks_between(anchor_date, d)
        weeks >= 0 && (weeks % expr.interval).zero?

      when MonthRepeat
        return false unless time_matches.call(expr.times)

        if expr.interval > 1
          anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
          month_offset = EvalHelpers.months_between_ym(anchor_date, d)
          return false if month_offset.negative? || (month_offset % expr.interval) != 0
        end
        matches_month_target(expr.target, d)

      when OrdinalRepeat
        return false unless time_matches.call(expr.times)

        if expr.interval > 1
          anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
          month_offset = EvalHelpers.months_between_ym(anchor_date, d)
          return false if month_offset.negative? || (month_offset % expr.interval) != 0
        end

        ordinal_target = if expr.ordinal == OrdinalPosition::LAST
          EvalHelpers.last_weekday_in_month(d.year, d.month, expr.day)
        else
          EvalHelpers.nth_weekday_of_month(d.year, d.month, expr.day,
            OrdinalPosition.to_n(expr.ordinal))
        end
        return false unless ordinal_target

        d == ordinal_target

      when SingleDateExpr
        return false unless time_matches.call(expr.times)

        matches_date_spec(expr.date, d)

      when YearRepeat
        return false unless time_matches.call(expr.times)

        if expr.interval > 1
          anchor_year = anchor ? Date.parse(anchor).year : EPOCH_DATE.year
          year_offset = d.year - anchor_year
          return false if year_offset.negative? || (year_offset % expr.interval) != 0
        end
        matches_year_target(expr.target, d)

      else
        false
      end
    end

    def self.time_matches_with_dst(times, d, dt, tz)
      times.any? do |tod|
        if dt.hour == tod.hour && dt.min == tod.minute
          true
        else
          # DST gap check
          resolved = EvalHelpers.at_time_on_date(d, tod, tz)
          resolved && resolved.to_i == dt.to_i
        end
      end
    end

    def self.matches_month_target(target, d)
      case target
      when DaysTarget
        expanded = Hron.expand_month_target(target)
        expanded.include?(d.day)
      when LastDayTarget
        d == EvalHelpers.last_day_of_month(d.year, d.month)
      when LastWeekdayTarget
        d == EvalHelpers.last_weekday_of_month(d.year, d.month)
      when NearestWeekdayTarget
        target_date = EvalHelpers.nearest_weekday(d.year, d.month, target.day, target.direction)
        target_date && d == target_date
      else
        false
      end
    end

    def self.matches_date_spec(date_spec, d)
      case date_spec
      when IsoDate
        d == Date.parse(date_spec.date)
      when NamedDate
        d.month == MonthName.number(date_spec.month) && d.day == date_spec.day
      else
        false
      end
    end

    def self.matches_year_target(target, d)
      case target
      when YearDateTarget
        d.month == MonthName.number(target.month) && d.day == target.day
      when YearOrdinalWeekdayTarget
        return false if d.month != MonthName.number(target.month)

        ordinal_date = if target.ordinal == OrdinalPosition::LAST
          EvalHelpers.last_weekday_in_month(d.year, d.month, target.weekday)
        else
          EvalHelpers.nth_weekday_of_month(d.year, d.month, target.weekday,
            OrdinalPosition.to_n(target.ordinal))
        end
        ordinal_date && d == ordinal_date
      when YearDayOfMonthTarget
        d.month == MonthName.number(target.month) && d.day == target.day
      when YearLastWeekdayTarget
        return false if d.month != MonthName.number(target.month)

        d == EvalHelpers.last_weekday_of_month(d.year, d.month)
      else
        false
      end
    end

    # Per-variant next functions
    def self.next_day_repeat(interval, days, times, tz, anchor, now)
      now_local = tz.utc_to_local(now.utc)
      d = now_local.to_date

      if interval <= 1
        if EvalHelpers.matches_day_filter(d, days)
          candidate = EvalHelpers.earliest_future_at_times(d, times, tz, now)
          return candidate if candidate
        end

        8.times do
          d += 1
          if EvalHelpers.matches_day_filter(d, days)
            candidate = EvalHelpers.earliest_future_at_times(d, times, tz, now)
            return candidate if candidate
          end
        end

        return nil
      end

      # Interval > 1
      anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
      offset = EvalHelpers.days_between(anchor_date, d)
      remainder = offset % interval
      aligned_date = remainder.zero? ? d : d + (interval - remainder)

      400.times do
        candidate = EvalHelpers.earliest_future_at_times(aligned_date, times, tz, now)
        return candidate if candidate

        aligned_date += interval
      end

      nil
    end

    def self.next_interval_repeat(interval, unit, from_time, to_time, day_filter, tz, now)
      step_minutes = (unit == IntervalUnit::MIN) ? interval : interval * 60
      from_minutes = (from_time.hour * 60) + from_time.minute
      to_minutes = (to_time.hour * 60) + to_time.minute

      # Convert now to local time in the target timezone
      now_local = tz.utc_to_local(now.utc)
      d = now_local.to_date

      400.times do
        if day_filter && !EvalHelpers.matches_day_filter(d, day_filter)
          d += 1
          next
        end

        same_day = d == now_local.to_date
        now_minutes = same_day ? (now_local.hour * 60) + now_local.min : -1

        next_slot = if now_minutes < from_minutes
          from_minutes
        else
          elapsed = now_minutes - from_minutes
          from_minutes + (((elapsed / step_minutes) + 1) * step_minutes)
        end

        # Try each slot within the day's window until we find one that exists
        # This handles DST gaps where intermediate times don't exist
        while next_slot <= to_minutes
          h = next_slot / 60
          m = next_slot % 60
          candidate = EvalHelpers.at_time_on_date(d, TimeOfDay.new(h, m), tz)
          return candidate if candidate && candidate > now

          # Slot didn't exist (DST gap) or wasn't in the future, try next slot
          next_slot += step_minutes
        end

        d += 1
      end

      nil
    end

    def self.next_week_repeat(interval, days, times, tz, anchor, now)
      anchor_date = anchor ? Date.parse(anchor) : EPOCH_MONDAY

      now_local = tz.utc_to_local(now.utc)
      d = now_local.to_date
      sorted_days = days.sort_by { |wd| Weekday.number(wd) }

      dow_offset = d.cwday - 1
      current_monday = d - dow_offset

      anchor_dow_offset = anchor_date.cwday - 1
      anchor_monday = anchor_date - anchor_dow_offset

      54.times do
        weeks = EvalHelpers.weeks_between(anchor_monday, current_monday)

        if weeks.negative?
          skip = (-weeks + interval - 1) / interval
          current_monday += skip * interval * 7
          next
        end

        if (weeks % interval).zero?
          sorted_days.each do |wd|
            day_offset = Weekday.number(wd) - 1
            target_date = current_monday + day_offset
            candidate = EvalHelpers.earliest_future_at_times(target_date, times, tz, now)
            return candidate if candidate
          end
        end

        remainder = weeks % interval
        skip_weeks = remainder.zero? ? interval : interval - remainder
        current_monday += skip_weeks * 7
      end

      nil
    end

    def self.next_month_repeat(interval, target, times, tz, anchor, now, during = [])
      now_local = tz.utc_to_local(now.utc)
      year = now_local.year
      month = now_local.month

      anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
      max_iter = (interval > 1) ? 24 * interval : 24

      # For NearestWeekday with direction, we need to apply the during filter here
      # because the result can cross month boundaries
      apply_during_filter = !during.empty? &&
        target.is_a?(NearestWeekdayTarget) &&
        !target.direction.nil?

      max_iter.times do
        # Check during filter for NearestWeekday with direction
        if apply_during_filter && !during.any? { |mn| MonthName.number(mn) == month }
          month += 1
          if month > 12
            month = 1
            year += 1
          end
          next
        end

        if interval > 1
          cur = Date.new(year, month, 1)
          month_offset = EvalHelpers.months_between_ym(anchor_date, cur)
          if month_offset.negative? || (month_offset % interval) != 0
            month += 1
            if month > 12
              month = 1
              year += 1
            end
            next
          end
        end

        date_candidates = []

        case target
        when DaysTarget
          expanded = Hron.expand_month_target(target)
          last = EvalHelpers.last_day_of_month(year, month)
          expanded.each do |day_num|
            next unless day_num <= last.day

            begin
              date_candidates << Date.new(year, month, day_num)
            rescue ArgumentError
              # Invalid date
            end
          end
        when LastDayTarget
          date_candidates << EvalHelpers.last_day_of_month(year, month)
        when LastWeekdayTarget
          date_candidates << EvalHelpers.last_weekday_of_month(year, month)
        when NearestWeekdayTarget
          nw = EvalHelpers.nearest_weekday(year, month, target.day, target.direction)
          date_candidates << nw if nw
        end

        best = nil
        date_candidates.each do |dc|
          candidate = EvalHelpers.earliest_future_at_times(dc, times, tz, now)
          best = candidate if candidate && (best.nil? || candidate < best)
        end
        return best if best

        month += 1
        if month > 12
          month = 1
          year += 1
        end
      end

      nil
    end

    def self.next_ordinal_repeat(interval, ordinal, day, times, tz, anchor, now)
      now_local = tz.utc_to_local(now.utc)
      year = now_local.year
      month = now_local.month

      anchor_date = anchor ? Date.parse(anchor) : EPOCH_DATE
      max_iter = (interval > 1) ? 24 * interval : 24

      max_iter.times do
        if interval > 1
          cur = Date.new(year, month, 1)
          month_offset = EvalHelpers.months_between_ym(anchor_date, cur)
          if month_offset.negative? || (month_offset % interval) != 0
            month += 1
            if month > 12
              month = 1
              year += 1
            end
            next
          end
        end

        ordinal_date = if ordinal == OrdinalPosition::LAST
          EvalHelpers.last_weekday_in_month(year, month, day)
        else
          EvalHelpers.nth_weekday_of_month(year, month, day, OrdinalPosition.to_n(ordinal))
        end

        if ordinal_date
          candidate = EvalHelpers.earliest_future_at_times(ordinal_date, times, tz, now)
          return candidate if candidate
        end

        month += 1
        if month > 12
          month = 1
          year += 1
        end
      end

      nil
    end

    def self.next_single_date(date_spec, times, tz, now)
      case date_spec
      when IsoDate
        d = Date.parse(date_spec.date)
        EvalHelpers.earliest_future_at_times(d, times, tz, now)
      when NamedDate
        now_local = tz.utc_to_local(now.utc)
        start_year = now_local.year
        8.times do |y|
          year = start_year + y
          begin
            d = Date.new(year, MonthName.number(date_spec.month), date_spec.day)
            candidate = EvalHelpers.earliest_future_at_times(d, times, tz, now)
            return candidate if candidate
          rescue ArgumentError
            # Invalid date
          end
        end
        nil
      end
    end

    def self.next_year_repeat(interval, target, times, tz, anchor, now)
      now_local = tz.utc_to_local(now.utc)
      start_year = now_local.year
      anchor_year = anchor ? Date.parse(anchor).year : EPOCH_DATE.year

      max_iter = (interval > 1) ? 8 * interval : 8

      max_iter.times do |y|
        year = start_year + y

        if interval > 1
          year_offset = year - anchor_year
          next if year_offset.negative? || (year_offset % interval) != 0
        end

        target_date = compute_year_target_date(target, year)
        next unless target_date

        candidate = EvalHelpers.earliest_future_at_times(target_date, times, tz, now)
        return candidate if candidate
      end

      nil
    end

    def self.compute_year_target_date(target, year)
      case target
      when YearDateTarget
        Date.new(year, MonthName.number(target.month), target.day)
      when YearOrdinalWeekdayTarget
        if target.ordinal == OrdinalPosition::LAST
          EvalHelpers.last_weekday_in_month(year, MonthName.number(target.month), target.weekday)
        else
          EvalHelpers.nth_weekday_of_month(year, MonthName.number(target.month), target.weekday,
            OrdinalPosition.to_n(target.ordinal))
        end
      when YearDayOfMonthTarget
        Date.new(year, MonthName.number(target.month), target.day)
      when YearLastWeekdayTarget
        EvalHelpers.last_weekday_of_month(year, MonthName.number(target.month))
      end
    rescue ArgumentError
      nil
    end
  end
end
