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

    # Resolves a fixed time per spec/README.md "DST spring-forward (gaps)" and "DST fall-back (ambiguous times)".
    def self.at_time_on_date(d, tod, tz)
      local = wall_time(d, tod)
      local - (utc_offset_at(local, tz) || offset_before_gap(local, tz))
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
      gap_transition(local, tz).previous_offset.utc_total_offset
    end

    # The spring-forward transition whose gap contains the wall time local.
    def self.gap_transition(local, tz)
      tz.transitions_up_to(local + DAY_SECONDS, local - DAY_SECONDS).rfind do |t|
        t.at.to_time + t.previous_offset.utc_total_offset <= local
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
    # Supported range: MIN_INSTANT <= t < MAX_INSTANT (spec/README.md "Supported range").
    MIN_INSTANT = Time.utc(1, 1, 2)
    MAX_INSTANT = Time.utc(9999, 12, 30)

    # Returns the next occurrence strictly after now, or nil if there is none in the supported range.
    def self.next_from(schedule, now)
      search(schedule, now, 1) if in_range?(now)
    end

    # Returns the latest occurrence strictly before now, or nil if there is none in the supported range.
    def self.previous_from(schedule, now)
      search(schedule, now, -1) if in_range?(now)
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

    # Returns a lazy Enumerator of occurrences where from < occurrence <= to, empty when either
    # bound is outside the supported range.
    def self.between(schedule, from, to)
      Enumerator.new do |yielder|
        next unless in_range?(to)

        occurrences(schedule, from).each do |dt|
          break if dt > to

          yielder << dt
        end
      end.lazy
    end

    # True when the minute containing dt, on the schedule's wall clock, is an occurrence.
    def self.matches(schedule, dt)
      return false unless in_range?(dt)

      local = TzResolver.resolve(schedule.timezone).to_local(dt)
      minute = dt - local.sec - local.subsec
      search(schedule, minute - 1, 1) == minute
    end

    def self.in_range?(time)
      time >= MIN_INSTANT && time < MAX_INSTANT
    end

    # Walks candidate days away from now, forward when dir is 1 and backward when it is -1,
    # and returns the closest occurrence strictly beyond now.
    def self.search(schedule, now, dir)
      expr = schedule.expr
      tz = TzResolver.resolve(schedule.timezone)
      until_date = schedule.until && EvalHelpers.resolve_until(schedule.until, now)
      starting = schedule.anchor && EvalHelpers.parse_date(schedule.anchor)
      from = tz.utc_to_local(now.utc).to_date.gregorian
      # A spring-forward shift can carry the previous date's fixed time past now, and a fall-back
      # overlap that crosses midnight can put the next date's first pass before now.
      if dir.positive?
        from -= 1 unless expr.is_a?(IntervalRepeat)
        from = [from, starting].max if starting
      else
        from += 1
        from = [from, until_date].min if until_date
      end
      best = nil

      each_candidate_day(expr, starting, from, dir) do |target, day|
        break if best && !could_beat?(best, day, tz, dir)
        if dir.positive?
          break if day.year > 9999 || (until_date && day > until_date)
          next if starting && day < starting
        else
          break if day.year < 1 || (starting && day < starting)
          next if until_date && day > until_date
        end
        next unless EvalHelpers.matches_during(target, schedule.during)
        next if EvalHelpers.is_excepted(day, schedule.except)

        found = occurrence_on(expr, day, tz, now, dir)
        best = found if found && (best.nil? || (dir.positive? ? found < best : found > best))
      end
      best if best && in_range?(best)
    end

    # A shift moves an occurrence at most onto the adjacent date, so a candidate day can still beat
    # best only if its occurrences may land on best's date.
    def self.could_beat?(best, day, tz, dir)
      landed = tz.utc_to_local(best.utc).to_date.gregorian
      dir.positive? ? day <= landed : day >= landed - 1
    end

    # Yields [target, day] for each candidate day in search order. day is the date an occurrence is
    # scheduled on, which the day filter, except, until and starting see even when a spring-forward
    # shift carries it onto the next date; target is the date whose month `during` checks, which
    # differs from day only for a nearest weekday (spec/README.md "Nearest weekday and during").
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
        each_period(from.jd.div(7), (starting || EPOCH_MONDAY).jd.div(7), expr.interval, CYCLE_WEEKS, dir) do |week|
          offsets.each do |offset|
            day = Date.jd((week * 7) + offset, Date::GREGORIAN)
            yield day, day
          end
        end
      when MonthRepeat
        # One extra month on the side the search comes from catches a nearest weekday that
        # crosses into from's month.
        each_period(month_number(from) - dir, month_number(starting || EPOCH_DATE), expr.interval, CYCLE_MONTHS, dir) do |number|
          year, month = number.divmod(12)
          target = EvalHelpers.date(year, month + 1, 1)
          days = month_target_days(expr.target, year, month + 1)
          days.reverse! if dir.negative?
          days.each { |day| yield target, day }
        end
      when YearRepeat
        each_period(from.year, (starting || EPOCH_DATE).year, expr.interval, CYCLE_YEARS, dir) do |year|
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
    def self.each_period(from, anchor, interval, cycle, dir)
      first = from + (dir * ((dir * (anchor - from)) % interval))
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
      return interval_slot_on(expr, day, tz, now, dir) if expr.is_a?(IntervalRepeat)

      instants = expr.times.map { |tod| EvalHelpers.at_time_on_date(day, tod, tz) }
      instants.select! { |t| dir.positive? ? t > now : t < now }
      dir.positive? ? instants.min : instants.max
    end

    # Slots follow spec/README.md "Interval slots in a spring-forward gap". Keyed by its instant, or
    # by the gap's transition instant when it has none, slots are in instant order, so a binary
    # search finds the slot closest beyond now.
    def self.interval_slot_on(expr, day, tz, now, dir)
      step = ((expr.unit == IntervalUnit::MIN) ? expr.interval : expr.interval * 60) * 60
      midnight = Time.utc(day.year, day.month, day.day)
      first_slot = midnight + (((expr.from_time.hour * 60) + expr.from_time.minute) * 60)
      last_slot = midnight + (((expr.to_time.hour * 60) + expr.to_time.minute) * 60)
      count = ((last_slot - first_slot) / step).floor + 1
      return nil if count <= 0

      instant = lambda do |k|
        wall = first_slot + (k * step)
        offset = EvalHelpers.utc_offset_at(wall, tz)
        offset ? wall - offset : nil
      end
      key = ->(k) { instant.call(k) || EvalHelpers.gap_transition(first_slot + (k * step), tz).at.to_time }

      if dir.positive?
        start = (0...count).bsearch { |k| key.call(k) > now }
        start && (start...count).lazy.filter_map(&instant).first
      else
        stop = (0...count).bsearch { |k| key.call(k) >= now } || count
        (0...stop).reverse_each.lazy.filter_map(&instant).first
      end
    end

    private_class_method :in_range?, :search, :could_beat?, :each_candidate_day, :each_period,
      :month_number, :valid_date, :month_target_days, :year_target_day, :ordinal_weekday,
      :occurrence_on, :interval_slot_on
  end
end
