# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"
require_relative "ast"
require_relative "error"

module Hron
  EPOCH_DATE = Date.new(1970, 1, 1)
  EPOCH_MONDAY = Date.new(1970, 1, 5)

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

  module EvalHelpers
    DAY_SECONDS = 86_400

    # Dates are proleptic Gregorian, so searches that reach back before 1582 stay on the same calendar.
    def self.date(year, month, day)
      Date.new(year, month, day, Date::GREGORIAN)
    end

    def self.parse_date(iso)
      Date.iso8601(iso, Date::GREGORIAN)
    end

    # A repeated (fall-back) time resolves to its first pass; a time inside a spring-forward gap
    # shifts forward by the length of the gap.
    def self.at_time_on_date(d, tod, tz)
      local = wall_time(d, tod)
      local - (utc_offset_at(local, tz) || offset_before_gap(local, tz))
    end

    # Like at_time_on_date, but nil for a time inside a spring-forward gap.
    def self.at_existing_time_on_date(d, tod, tz)
      local = wall_time(d, tod)
      offset = utc_offset_at(local, tz)
      local - offset if offset
    end

    # The wall-clock time as a UTC Time, so the system timezone never interferes.
    def self.wall_time(d, tod)
      Time.utc(d.year, d.month, d.day, tod.hour, tod.minute)
    end

    def self.utc_offset_at(local, tz)
      tz.periods_for_local(local).first&.offset&.utc_total_offset
    end

    # Interpreting a gap time with the offset in force before the gap is what shifts it forward.
    def self.offset_before_gap(local, tz)
      transition = tz.transitions_up_to(local + DAY_SECONDS, local - DAY_SECONDS).rfind do |t|
        t.at.to_time + t.previous_offset.utc_total_offset <= local
      end
      transition.previous_offset.utc_total_offset
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
      Date.new(year, month, -1, Date::GREGORIAN)
    end

    def self.last_weekday_of_month(year, month)
      d = last_day_of_month(year, month)
      d -= 1 while d.cwday >= 6
      d
    end

    # Returns nil if target_day does not exist in the month. A nil direction never
    # leaves the month (cron W); a direction may cross it.
    def self.nearest_weekday(year, month, target_day, direction)
      last = last_day_of_month(year, month)
      last_day_num = last.day

      return nil if target_day > last_day_num

      date = date(year, month, target_day)
      dow = date.cwday # Monday=1 ... Sunday=7

      return date if dow.between?(1, 5)

      case direction
      when nil
        # Standard cron W behavior: never cross month boundary
        if dow == 6 && target_day == 1
          date + 2
        elsif dow == 6
          date - 1
        elsif target_day >= last_day_num
          date - 2
        else
          date + 1
        end

      when NearestDirection::NEXT
        if dow == 6 # Saturday -> Monday
          date + 2
        else # Sunday -> Monday
          date + 1
        end

      when NearestDirection::PREVIOUS
        if dow == 6 # Saturday -> Friday
          date - 1
        else # Sunday -> Friday (go back 2 days)
          date - 2
        end
      end
    end

    def self.nth_weekday_of_month(year, month, weekday, n)
      target_dow = Weekday.number(weekday)
      d = date(year, month, 1)
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

    def self.is_excepted(d, exceptions)
      exceptions.any? do |exc|
        case exc
        when NamedException
          d.month == MonthName.number(exc.month) && d.day == exc.day
        when IsoException
          d == parse_date(exc.date)
        else
          false
        end
      end
    end

    def self.matches_during(d, during)
      return true if during.empty?

      during.any? { |mn| MonthName.number(mn) == d.month }
    end

    def self.resolve_until(until_spec, now)
      case until_spec
      when IsoUntil
        parse_date(until_spec.date)
      when NamedUntil
        year = now.year
        [year, year + 1].each do |y|
          d = date(y, MonthName.number(until_spec.month), until_spec.day)
          return d if d >= now.to_date
        rescue ArgumentError
          next
        end
        date(year + 1, MonthName.number(until_spec.month), until_spec.day)
      end
    end
  end

  class Evaluator
    # The proleptic Gregorian calendar repeats every 400 years: this many days, weeks, months and years.
    CYCLE_DAYS = 146_097
    CYCLE_WEEKS = 20_871
    CYCLE_MONTHS = 4800
    CYCLE_YEARS = 400
    MIN_YEAR = 1
    MAX_YEAR = 9999

    def self.next_from(schedule, now)
      search(schedule, now, 1)
    end

    def self.previous_from(schedule, now)
      search(schedule, now, -1)
    end

    # Walks candidate days away from now, forward when dir is 1 and backward when it is -1,
    # and returns the closest occurrence strictly beyond now within years 1 to 9999.
    def self.search(schedule, now, dir)
      tz = TzResolver.resolve(schedule.timezone)
      until_date = schedule.until && EvalHelpers.resolve_until(schedule.until, now)
      starting = schedule.anchor && EvalHelpers.parse_date(schedule.anchor)
      from = tz.utc_to_local(now.utc).to_date.gregorian
      # A spring-forward shift can carry the previous day's occurrence past now.
      from -= 1 if dir.positive?
      from = [from, until_date].min if dir.negative? && until_date
      best = nil

      each_candidate_day(schedule.expr, starting, from, dir) do |target, day|
        break if best && !could_beat?(best, day, tz, dir)
        if dir.positive?
          break if day.year > MAX_YEAR || (until_date && day > until_date)
        else
          break if day.year < MIN_YEAR || (starting && day < starting)
          next if until_date && day > until_date
        end
        next unless EvalHelpers.matches_during(target, schedule.during)
        next if EvalHelpers.is_excepted(day, schedule.except)

        found = occurrence_on(schedule.expr, day, tz, now, dir)
        best = found if found && (best.nil? || (dir.positive? ? found < best : found > best))
      end
      best
    end

    # A shift moves an occurrence at most onto the next date, so a candidate day can still beat
    # best only if its occurrences may land on best's date.
    def self.could_beat?(best, day, tz, dir)
      landed = tz.utc_to_local(best.utc).to_date.gregorian
      dir.positive? ? day <= landed : day >= landed - 1
    end

    def self.each_candidate_day(expr, starting, from, dir)
      case expr
      when DayRepeat, IntervalRepeat
        interval, filter = expr.is_a?(DayRepeat) ? [expr.interval, expr.days] : [1, expr.day_filter]
        each_period(from.jd, (starting || EPOCH_DATE).jd, interval, CYCLE_DAYS, dir) do |jd|
          day = Date.jd(jd, Date::GREGORIAN)
          yield day, day if filter.nil? || EvalHelpers.matches_day_filter(day, filter)
        end
      when WeekRepeat
        offsets = expr.days.map { |wd| Weekday.number(wd) - 1 }.uniq.sort
        offsets.reverse! if dir.negative?
        # Julian day numbers that are multiples of 7 are Mondays, so jd.div(7) numbers ISO weeks.
        each_period(from.jd.div(7), (starting || EPOCH_MONDAY).jd.div(7), expr.interval, CYCLE_WEEKS, dir, bounded: starting) do |week|
          offsets.each do |offset|
            day = Date.jd((week * 7) + offset, Date::GREGORIAN)
            yield day, day
          end
        end
      when MonthRepeat
        # Starts one month back so a nearest weekday that crosses into this month is not missed.
        each_period(month_number(from) - dir, month_number(starting || EPOCH_DATE), expr.interval, CYCLE_MONTHS, dir, bounded: starting && expr.interval > 1) do |number|
          year, month = number.divmod(12)
          target = EvalHelpers.date(year, month + 1, 1)
          days = month_target_days(expr.target, year, month + 1)
          days.reverse! if dir.negative?
          days.each { |day| yield target, day }
        end
      when YearRepeat
        each_period(from.year, (starting || EPOCH_DATE).year, expr.interval, CYCLE_YEARS, dir, bounded: starting && expr.interval > 1) do |year|
          day = year_target_day(expr.target, year)
          yield day, day if day
        end
      when SingleDateExpr
        case expr.date
        when IsoDate
          day = EvalHelpers.parse_date(expr.date.date)
          yield day, day
        when NamedDate
          each_period(from.year, from.year, 1, CYCLE_YEARS, dir) do |year|
            day = valid_date(year, MonthName.number(expr.date.month), expr.date.day)
            yield day, day if day
          end
        end
      end
    end

    # Yields period numbers (days, weeks, months or years) from `from` in direction dir that are a
    # whole number of intervals from anchor, covering lcm(400 years, interval): the search horizon.
    # When bounded, a forward search starts no earlier than the anchor's period, which is how an
    # explicit `starting` date limits week repeats and month or year intervals over 1.
    def self.each_period(from, anchor, interval, cycle, dir, bounded: false)
      first = from + (dir * ((dir * (anchor - from)) % interval))
      first = anchor if bounded && dir.positive? && first < anchor
      ((cycle.lcm(interval) / interval) + 1).times { |k| yield first + (dir * interval * k) }
    end

    def self.month_number(date)
      (date.year * 12) + date.month - 1
    end

    def self.valid_date(year, month, day)
      EvalHelpers.date(year, month, day) if Date.valid_date?(year, month, day, Date::GREGORIAN)
    end

    def self.month_target_days(target, year, month)
      case target
      when DaysTarget
        Hron.expand_month_target(target).uniq.sort.filter_map { |day| valid_date(year, month, day) }
      when LastDayTarget
        [EvalHelpers.last_day_of_month(year, month)]
      when LastWeekdayTarget
        [EvalHelpers.last_weekday_of_month(year, month)]
      when NearestWeekdayTarget
        [EvalHelpers.nearest_weekday(year, month, target.day, target.direction)].compact
      when OrdinalWeekdayTarget
        [ordinal_weekday(target.ordinal, year, month, target.weekday)].compact
      end
    end

    def self.year_target_day(target, year)
      month = MonthName.number(target.month)
      case target
      when YearDateTarget, YearDayOfMonthTarget
        valid_date(year, month, target.day)
      when YearOrdinalWeekdayTarget
        ordinal_weekday(target.ordinal, year, month, target.weekday)
      when YearLastWeekdayTarget
        EvalHelpers.last_weekday_of_month(year, month)
      end
    end

    def self.ordinal_weekday(ordinal, year, month, weekday)
      if ordinal == OrdinalPosition::LAST
        EvalHelpers.last_weekday_in_month(year, month, weekday)
      else
        EvalHelpers.nth_weekday_of_month(year, month, weekday, OrdinalPosition.to_n(ordinal))
      end
    end

    # The occurrence on day closest to now that is strictly beyond it in direction dir.
    def self.occurrence_on(expr, day, tz, now, dir)
      beyond = ->(t) { dir.positive? ? t > now : t < now }

      if expr.is_a?(IntervalRepeat)
        slots = interval_slots(expr)
        slots.reverse! if dir.negative?
        slots.each do |tod|
          t = EvalHelpers.at_existing_time_on_date(day, tod, tz)
          return t if t && beyond.call(t)
        end
        nil
      else
        instants = expr.times.map { |tod| EvalHelpers.at_time_on_date(day, tod, tz) }.select(&beyond)
        dir.positive? ? instants.min : instants.max
      end
    end

    # Slots are wall-clock times from the from time up to and including the to time.
    def self.interval_slots(expr)
      step = (expr.unit == IntervalUnit::MIN) ? expr.interval : expr.interval * 60
      first = (expr.from_time.hour * 60) + expr.from_time.minute
      last = (expr.to_time.hour * 60) + expr.to_time.minute
      first.step(last, step).map { |minutes| TimeOfDay.new(*minutes.divmod(60)) }
    end

    def self.next_n_from(schedule, now, n)
      results = []
      current = now
      n.times do
        nxt = next_from(schedule, current)
        break unless nxt

        results << nxt
        current = nxt
      end
      results
    end

    # Returns a lazy Enumerator of occurrences strictly after from. Unbounded for
    # repeating schedules unless an until clause ends them.
    def self.occurrences(schedule, from)
      Enumerator.new do |yielder|
        current = from
        loop do
          nxt = next_from(schedule, current)
          break unless nxt

          yielder << nxt
          current = nxt
        end
      end.lazy
    end

    # Returns a lazy Enumerator of occurrences where from < occurrence <= to.
    def self.between(schedule, from, to)
      Enumerator.new do |yielder|
        occurrences(schedule, from).each do |dt|
          break if dt > to

          yielder << dt
        end
      end.lazy
    end

    # True when the minute containing dt (its seconds dropped) is an occurrence.
    def self.matches(schedule, dt)
      minute = dt - dt.sec - dt.subsec
      next_from(schedule, minute - 1) == minute
    end
  end
end
