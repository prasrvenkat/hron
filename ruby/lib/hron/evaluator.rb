# frozen_string_literal: true

require "date"
require "time"
require "tzinfo"
require_relative "ast"
require_relative "error"
require_relative "eval/calendar"
require_relative "eval/wall_clock"

module Hron
  class Evaluator
    # Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment").
    EPOCH_MONDAY = Date.new(1970, 1, 5, Date::GREGORIAN)

    EPOCH_DATE = Date.new(1970, 1, 1, Date::GREGORIAN)

    # spec/README.md, "Supported range".
    SUPPORTED_RANGE = Time.utc(1, 1, 2)...Time.utc(9999, 12, 30)

    # Slack beyond the horizon for the period one behind the first date's, where a
    # search starts, and for a horizon that starts mid-period.
    HORIZON_MARGIN_PERIODS = 2

    # How many dates past its scheduled date a fixed time can land: one shifted out of a gap
    # before midnight lands on the next date.
    MAX_SHIFT_DAYS = 1

    # How many dates behind a date that has begun now's wall date can read: from the second
    # pass of a fall-back overlap that crosses midnight, one.
    MAX_OVERLAP_DAYS = 1

    # Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
    NAMED_UNTIL_MAX_YEARS = 8

    # Shared with Cron.to_cron, so conversion never disagrees with evaluation.
    def self.interval_slots(interval, unit, from, to)
      step = (unit == IntervalUnit::MIN) ? interval : interval * WallClock::MINUTES_PER_HOUR
      (WallClock.minute_of_day(from)..WallClock.minute_of_day(to)).step(step).to_a
    end

    def self.next_from(schedule, now)
      require_time(now, "now")
      Search.new(schedule).nearest(now, Direction::FORWARD) if SUPPORTED_RANGE.cover?(now)
    end

    def self.previous_from(schedule, now)
      require_time(now, "now")
      Search.new(schedule).nearest(now, Direction::BACKWARD) if SUPPORTED_RANGE.cover?(now)
    end

    # Not Enumerable#first, which raises RangeError for an n past a machine integer, where
    # n only caps the count (spec/README.md, "Timestamps and counts").
    def self.next_n_from(schedule, now, n)
      require_time(now, "now")
      raise TypeError, "n must be an Integer, not #{n.class}" unless n.is_a?(Integer)

      results = []
      return results unless n.positive?

      occurrences(schedule, now).each do |occurrence|
        results << occurrence
        break if results.size == n
      end
      results
    end

    def self.occurrences(schedule, from)
      require_time(from, "from")
      Enumerator.new do |yielder|
        next unless SUPPORTED_RANGE.cover?(from)

        search = Search.new(schedule)
        current = from
        while (current = search.nearest(current, Direction::FORWARD))
          yielder << current
        end
      end.lazy
    end

    def self.between(schedule, from, to)
      require_time(from, "from")
      require_time(to, "to")
      Enumerator.new do |yielder|
        next unless SUPPORTED_RANGE.cover?(to)

        occurrences(schedule, from).each do |instant|
          break if instant > to

          yielder << instant
        end
      end.lazy
    end

    # Defined through the forward search, so the two cannot disagree (spec/README.md,
    # "matches is true exactly when the minute containing t is an occurrence").
    def self.matches(schedule, dt)
      require_time(dt, "datetime")
      return false unless SUPPORTED_RANGE.cover?(dt)

      search = Search.new(schedule)
      local = search.zone.to_local(dt)
      minute = dt - local.sec - local.subsec
      # Occurrences fall on whole seconds, so none lies between this and the minute.
      just_before = minute - 1
      # An occurrence never lands before the date it is scheduled on, so one at this minute
      # is scheduled on or before the minute's wall date.
      search.clauses.end_on(local.to_date.gregorian)
      search.nearest(just_before, Direction::FORWARD) == minute
    end

    # A usage error, never a HronError (spec/README.md, "Timestamps and counts").
    def self.require_time(value, name)
      raise TypeError, "#{name} must be a Time, not #{value.class}" unless value.is_a?(Time)
    end
    private_class_method :require_time

    class Direction
      attr_reader :sign

      def initialize(sign)
        @sign = sign
        @forward = sign.positive?
      end

      def forward?
        @forward
      end

      def precedes?(a, b)
        @forward ? a < b : a > b
      end

      def in_order(items)
        (@forward || items.size < 2) ? items : items.reverse
      end

      FORWARD = new(1)
      BACKWARD = new(-1)
      private_class_method :new
    end

    class Search
      attr_reader :zone, :clauses

      def initialize(schedule)
        name = schedule.timezone
        @zone = TZInfo::Timezone.get(name || "UTC")
        @result_zone = name ? @zone : "UTC"
        @clauses = Clauses.new(schedule)
        @cadence = Cadence.of(schedule.expr, @clauses.starting)
        @times = DailyTimes.of(schedule.expr)
        @expr = schedule.expr
      end

      def nearest(now, direction)
        now = @zone.utc_to_local(now.getutc)
        now_date = now.to_date.gregorian
        first_date = @clauses.clamp(now_date, direction)
        # A nearest weekday or a DST shift can move an occurrence out of the period it is
        # scheduled in, so the search starts one period back.
        first_period = @cadence.period_of(first_date) - direction.sign
        farthest = @clauses.farthest_except_date(direction)
        reach = farthest ? @cadence.period_of(farthest) : first_period
        shift = @times.max_shift_days
        best = nil
        each_candidate(first_period, reach, direction) do |candidate|
          date = candidate.date
          break if best && !could_beat?(date, best.landing, direction, shift)
          break if @clauses.ends_search?(date, direction)
          next if behind?(date, now_date, direction, shift) || !@clauses.allows?(candidate)

          occurrence = nearest_on_date(date, now, direction)
          best = occurrence if occurrence && (best.nil? || direction.precedes?(occurrence.instant, best.instant))
        end
        Time.at(best.instant, in: @result_zone) if best && SUPPORTED_RANGE.cover?(best.instant)
      end

      private

      def each_candidate(first_period, reach, direction, &)
        @cadence.period_starts(first_period, reach, direction) do |start|
          direction.in_order(candidates_in_period(start)).each(&) unless rejects_period?(start)
        end
      end

      # A day or month period's candidates all target its own month, so one whose month
      # during rejects holds nothing.
      def rejects_period?(start)
        unit = @cadence.unit
        (unit == :day || unit == :month) && !@clauses.allows_month?(start.month)
      end

      def candidates_in_period(start)
        case @expr
        when DayRepeat
          Calendar.matches_day_filter?(start, @expr.days) ? [Candidate.on(start)] : []
        when IntervalRepeat
          Calendar.matches_day_filter?(start, @expr.day_filter) ? [Candidate.on(start)] : []
        when WeekRepeat
          @expr.days.map { |day| start + (Weekday.number(day) - 1) }.uniq.sort.map { |date| Candidate.on(date) }
        when MonthRepeat
          Calendar.month_target_dates(start.year, start.month, @expr.target).map { |date| Candidate.new(date, start.month) }
        when YearRepeat
          date = Calendar.year_target_date(start.year, @expr.target)
          date ? [Candidate.on(date)] : []
        when SingleDateExpr
          date = @expr.date.is_a?(IsoDate) ? start : Calendar.date(start.year, MonthName.number(@expr.date.month), @expr.date.day)
          date ? [Candidate.on(date)] : []
        end
      end

      # An occurrence lands from its scheduled date to shift dates after it, on a first pass,
      # and first passes keep wall-clock order.
      def could_beat?(date, landing, direction, shift)
        direction.forward? ? date <= landing : Calendar.days_between(date, landing) <= shift
      end

      def behind?(date, now_date, direction, shift)
        if direction.forward?
          Calendar.days_between(date, now_date) > shift
        else
          Calendar.days_between(now_date, date) > MAX_OVERLAP_DAYS
        end
      end

      def nearest_on_date(date, now, direction)
        case @times
        when DailyTimes::Fixed
          # Every time is compared: one shifted out of a gap can land after a later wall time.
          nearest = landing = nil
          @times.times.each do |time|
            instant, lands_on = WallClock.fixed_time_on(date, time, @zone)
            next if !direction.precedes?(now, instant) || (nearest && !direction.precedes?(instant, nearest))

            nearest = instant
            landing = lands_on
          end
          Occurrence.new(nearest, landing) if nearest
        when DailyTimes::Slots
          instant = nearest_slot(date, now, direction)
          # A slot outside a gap is the first pass of its wall time, so it lands on its date.
          Occurrence.new(instant, date) if instant
        end
      end

      # Slot keys never decrease in wall-clock order, so one binary search finds where the
      # slots past now begin.
      def nearest_slot(date, now, direction)
        minutes = @times.minutes
        forward = direction.forward?
        low = 0
        high = minutes.size
        below = above = nil
        while low < high
          middle = (low + high) / 2
          slot = WallClock.slot_on(date, minutes[middle], @zone)
          if forward ? slot.key > now : slot.key >= now
            high = middle
            above = slot
          else
            low = middle + 1
            below = slot
          end
        end
        index, slot = forward ? [low, above] : [low - 1, below]
        while index >= 0 && index < minutes.size
          slot ||= WallClock.slot_on(date, minutes[index], @zone)
          return slot.instant if slot.instant

          slot = nil
          index += direction.sign
        end
        nil
      end
    end

    Occurrence = Data.define(:instant, :landing)

    # target_month differs from date's month only when a directional nearest weekday crosses
    # into the adjacent month. A Struct, as one is made for every date a search walks and a
    # Data costs twice as much to make.
    Candidate = Struct.new(:date, :target_month) do
      def self.on(date)
        new(date, date.month)
      end
    end

    module DailyTimes
      Fixed = Data.define(:times) do
        def max_shift_days
          MAX_SHIFT_DAYS
        end
      end

      # Each slot is skipped in a gap, so it lands on its own date.
      Slots = Data.define(:minutes) do
        def max_shift_days
          0
        end
      end

      def self.of(expr)
        return Fixed.new(expr.times) unless expr.is_a?(IntervalRepeat)

        Slots.new(Evaluator.interval_slots(expr.interval, expr.unit, expr.from_time, expr.to_time))
      end
    end

    # during applies to a candidate's target month; except, until and starting to its date
    # (spec/README.md, "Nearest weekday and `during`", "The `starting` clause").
    class Clauses
      attr_reader :starting

      def initialize(schedule)
        @starting = schedule.anchor && Calendar.parse_date(schedule.anchor)
        @until = schedule.until && resolve_until(schedule.until, @starting)
        named, iso = schedule.except.partition { |exception| exception.is_a?(NamedException) }
        @except_month_days = named.map { |exception| [MonthName.number(exception.month), exception.day] }
        @except_dates = iso.map { |exception| Calendar.parse_date(exception.date) }
        @during = schedule.during.map { |month| MonthName.number(month) }
      end

      def allows?(candidate)
        date = candidate.date
        allows_month?(candidate.target_month) &&
          @except_month_days.none? { |month, day| date.month == month && date.day == day } &&
          !@except_dates.include?(date) &&
          (@until.nil? || date <= @until) &&
          (@starting.nil? || date >= @starting)
      end

      def allows_month?(month)
        @during.empty? || @during.include?(month)
      end

      def end_on(date)
        @until = date if @until.nil? || date < @until
      end

      # The one-off except date farthest along direction: the calendar repeats only beyond
      # it (spec/README.md, "Search horizon").
      def farthest_except_date(direction)
        direction.forward? ? @except_dates.max : @except_dates.min
      end

      def clamp(date, direction)
        if direction.forward?
          @starting ? [date, @starting].max : date
        else
          @until ? [date, @until].min : date
        end
      end

      def ends_search?(date, direction)
        if direction.forward?
          !@until.nil? && date > @until
        else
          !@starting.nil? && date < @starting
        end
      end

      private

      # A named until date is the first such date on or after the starting date, which a
      # named until always has (spec/README.md, "Named `until`"). nil when the date never
      # occurs, so nothing bounds the schedule.
      def resolve_until(until_spec, starting)
        case until_spec
        when IsoUntil then Calendar.parse_date(until_spec.date)
        when NamedUntil
          month = MonthName.number(until_spec.month)
          (0..NAMED_UNTIL_MAX_YEARS)
            .filter_map { |k| Calendar.date(starting.year + k, month, until_spec.day) }
            .find { |date| date >= starting }
        end
      end
    end

    class Cadence
      attr_reader :unit

      # Units in 400 years, after which the proleptic Gregorian calendar repeats.
      PER_400_YEARS = {day: 146_097, week: 20_871, month: 4800, year: 400}.freeze

      def self.of(expr, starting)
        unit, interval, default_anchor = case expr
        in SingleDateExpr[date: IsoDate[date:]] then return new(:day, Calendar.parse_date(date), 1, single: true)
        in SingleDateExpr then [:year, 1, EPOCH_DATE]
        in IntervalRepeat then [:day, 1, EPOCH_DATE]
        in DayRepeat then [:day, expr.interval, EPOCH_DATE]
        in WeekRepeat then [:week, expr.interval, EPOCH_MONDAY]
        in MonthRepeat then [:month, expr.interval, EPOCH_DATE]
        in YearRepeat then [:year, expr.interval, EPOCH_DATE]
        end
        anchor = starting || default_anchor
        origin = case unit
        when :day then anchor
        when :week then Calendar.monday_of_week(anchor)
        when :month then Calendar.date(anchor.year, anchor.month, 1)
        when :year then Calendar.first_of_year(anchor.year)
        end
        new(unit, origin, interval)
      end

      def initialize(unit, origin, interval, single: false)
        @unit = unit
        @origin = origin
        @interval = interval
        @single = single
        @origin_month = Calendar.month_index(origin)
        # A nearest weekday can move a candidate into the calendar from the period on
        # either side of it.
        @earliest = period_of(Calendar::FIRST_DATE) - 1
        @latest = period_of(Calendar::LAST_DATE) + 1
      end

      def period_of(date)
        case @unit
        when :day then Calendar.days_between(@origin, date)
        when :week then Calendar.days_between(@origin, date).div(7)
        when :month then Calendar.month_index(date) - @origin_month
        when :year then date.year - @origin.year
        end
      end

      def start_of(k)
        case @unit
        when :day then @origin + k
        when :week then @origin + (k * 7)
        when :month then Calendar.first_of_month(@origin_month + k)
        when :year then Calendar.first_of_year(@origin.year + k)
        end
      end

      # Walks one search horizon beyond whichever of first_period and reach is farther along
      # direction (spec/README.md, "Search horizon").
      def period_starts(first_period, reach, direction)
        return yield @origin if @single

        first = align(first_period, direction)
        beyond = direction.sign * (align(reach, direction) - first)
        count = horizon_periods + HORIZON_MARGIN_PERIODS + ([beyond, 0].max / @interval)
        # A walk starts inside the calendar, at now or a starting date, and ends at its edge.
        far = direction.sign * ((direction.forward? ? @latest : @earliest) - first)
        inside = 0...[(far / @interval) + 1, count].min
        step = direction.sign * @interval
        inside.each { |i| yield start_of(first + (i * step)) }
      end

      private

      def align(k, direction)
        direction.forward? ? k + (-k % @interval) : k - (k % @interval)
      end

      # Aligned periods in lcm(400 years, interval units), after which both the calendar and
      # the alignment repeat.
      def horizon_periods
        cycle = PER_400_YEARS.fetch(@unit)
        cycle / cycle.gcd(@interval)
      end
    end

    private_constant :EPOCH_MONDAY, :EPOCH_DATE, :SUPPORTED_RANGE, :HORIZON_MARGIN_PERIODS, :MAX_SHIFT_DAYS, :NAMED_UNTIL_MAX_YEARS,
      :Direction, :Search, :Occurrence, :Candidate, :DailyTimes, :Clauses, :Cadence,
      :Calendar, :WallClock
  end
end
