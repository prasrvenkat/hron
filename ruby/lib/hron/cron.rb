# frozen_string_literal: true

require_relative "ast"
require_relative "error"
require_relative "evaluator"

module Hron
  module Cron
    MAX_LISTED_TIMES = 24
    BOTH_DAYS_RESTRICTED =
      "not expressible in hron: cron fires on either the day of month or the day of week"
    INTERVAL_DAYS =
      "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days"
    MINUTES_PER_DAY = 24 * 60
    MIDNIGHT = TimeOfDay.new(0, 0)
    END_OF_DAY = TimeOfDay.new(23, 59)

    # Digit strings may be of any length. Every number at or above this cap is out
    # of every field's range and steps past every range's end, so saturating at it
    # keeps each comparison exact.
    NUMBER_CAP = 1000

    MONTH_NAMES = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
    DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze
    WEEKDAYS = [
      Weekday::SUNDAY, Weekday::MONDAY, Weekday::TUESDAY, Weekday::WEDNESDAY,
      Weekday::THURSDAY, Weekday::FRIDAY, Weekday::SATURDAY
    ].freeze
    ORDINALS = [
      OrdinalPosition::FIRST, OrdinalPosition::SECOND, OrdinalPosition::THIRD,
      OrdinalPosition::FOURTH, OrdinalPosition::FIFTH
    ].freeze

    SHORTCUTS = {
      "@yearly" => "0 0 1 1 *",
      "@annually" => "0 0 1 1 *",
      "@monthly" => "0 0 1 * *",
      "@weekly" => "0 0 * * 0",
      "@daily" => "0 0 * * *",
      "@midnight" => "0 0 * * *",
      "@hourly" => "0 * * * *"
    }.freeze

    Field = Data.define(:name, :min, :max, :star_end, :names)
    MINUTE = Field.new("minute", 0, 59, 59, [])
    HOUR = Field.new("hour", 0, 23, 23, [])
    DAY_OF_MONTH = Field.new("day of month", 1, 31, 31, [])
    MONTH = Field.new("month", 1, 12, 12, MONTH_NAMES)
    # 7 is Sunday only where written: `*` and `a/n` end at 6.
    DAY_OF_WEEK = Field.new("day of week", 0, 7, 6, DAY_NAMES)

    Item = Data.define(:bounds, :step)

    private_constant :MAX_LISTED_TIMES, :BOTH_DAYS_RESTRICTED, :INTERVAL_DAYS, :MINUTES_PER_DAY,
      :MIDNIGHT, :END_OF_DAY, :NUMBER_CAP, :MONTH_NAMES, :DAY_NAMES, :WEEKDAYS, :ORDINALS,
      :SHORTCUTS, :Field, :MINUTE, :HOUR, :DAY_OF_MONTH, :MONTH, :DAY_OF_WEEK, :Item

    class << self
      def from_cron(input)
        text = trim(utf8(input))
        text = shortcut(text) if text.start_with?("@")
        fields = text.split(/[ \t]+/)
        raise HronError.cron("expected 5 cron fields, got #{fields.length}") unless fields.length == 5

        minute, hour, day_of_month, month, day_of_week = fields
        minutes = values(minute, MINUTE).sort
        hours = values(hour, HOUR).sort
        month_days = parse_day_of_month(day_of_month)
        months = values(month, MONTH).sort
        week_days = parse_day_of_week(day_of_week)
        days = day_expression(month_days, week_days)
        times = hours.flat_map { |h| minutes.map { |m| TimeOfDay.new(h, m) } }

        gap = equal_gap(times)
        expr = if days.key?(:of_week) && gap
          interval(times, gap, days[:of_week])
        elsif times.length > MAX_LISTED_TIMES
          raise too_many_times(times.length, gap)
        elsif (target = year_target(days, months))
          YearRepeat.new(1, target, times)
        elsif days.key?(:of_week)
          DayRepeat.new(1, days[:of_week], times)
        else
          MonthRepeat.new(1, days[:of_month], times)
        end
        yearly = expr.is_a?(YearRepeat)
        during = (!yearly && months.length < MonthName::ALL.length) ? months.map { |m| MonthName::ALL[m - 1] } : []
        ScheduleData.new(expression: expr, during: during)
      end

      def to_cron(schedule)
        raise not_expressible("except clauses not supported") unless schedule.except.empty?
        raise not_expressible("until clauses not supported") if schedule.until
        raise not_expressible("starting clauses not supported") if schedule.starting

        day_of_month, day_of_week = day_fields(schedule.expression)
        month = month_field(schedule)
        minute, hour = time_fields(schedule.expression)
        "#{minute} #{hour} #{day_of_month} #{month} #{day_of_week}"
      end

      private

      # Error messages echo the input, so they must be valid UTF-8. No byte outside ASCII
      # is valid cron, so replacing one changes no result. BINARY text, and text in an
      # encoding Ruby has no converter for, is read as UTF-8.
      def utf8(input)
        return as_utf8(input) if input.encoding == Encoding::BINARY

        input.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).scrub
      rescue Encoding::ConverterNotFoundError
        as_utf8(input)
      end

      def as_utf8(input)
        input.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # String#strip would also strip NUL, vertical tab and form feed.
      def trim(text)
        first = text.index(/[^ \t\r\n]/)
        first ? text[first..text.rindex(/[^ \t\r\n]/)] : ""
      end

      def shortcut(input)
        SHORTCUTS.fetch(input.downcase(:ascii)) do
          raise HronError.cron("unknown cron shortcut: #{input}")
        end
      end

      def parse_day_of_month(text)
        return :any if text == "*" || text == "?"
        return :last if text.downcase(:ascii) == "l"
        return :last_weekday if text.downcase(:ascii) == "lw"

        day = text[0...-1]
        return {nearest: field_value(day, DAY_OF_MONTH)} if text.end_with?("W", "w") && number?(day)

        {days: values(text, DAY_OF_MONTH)}
      end

      def parse_day_of_week(text)
        return :any if text == "*" || text == "?"

        day, hash, nth = text.partition("#")
        if !hash.empty? && value?(day, DAY_OF_WEEK) && number?(nth)
          weekday = WEEKDAYS[field_value(day, DAY_OF_WEEK) % 7]
          n = number(nth)
          raise HronError.cron("day of week ordinal must be 1-5, got #{nth}") unless n.between?(1, 5)

          return {nth: n, weekday: weekday}
        end
        day = text[0...-1]
        return {last: WEEKDAYS[field_value(day, DAY_OF_WEEK) % 7]} if text.end_with?("L", "l") && value?(day, DAY_OF_WEEK)

        {days: values(text, DAY_OF_WEEK)}
      end

      # Keeps the order of first appearance, in which from_cron lists days of the week.
      def values(text, field)
        items = items(text, field)
        raise HronError.cron("invalid #{field.name}: #{text}") unless items

        values = []
        items.each do |item|
          first, last = case item.bounds
          in :star
            [field.min, field.star_end]
          in [a]
            first = field_value(a, field)
            # `7/n` starts past the end of `*`, so it is Sunday alone.
            [first, item.step ? [first, field.star_end].max : first]
          in [a, b]
            first = field_value(a, field)
            last = field_value(b, field)
            raise HronError.cron("#{field.name} range must not run backwards: #{a}-#{b}") if first > last

            [first, last]
          end
          step = item.step ? number(item.step) : 1
          raise HronError.cron("#{field.name} step must be at least 1") if step.zero?

          first.step(last, step) do |value|
            value %= 7 if field == DAY_OF_WEEK
            values << value unless values.include?(value)
          end
        end
        values
      end

      def items(text, field)
        text.split(",", -1).map do |item|
          range, slash, step = item.partition("/")
          step = nil if slash.empty?
          first, dash, last = range.partition("-")
          bounds = if range == "*"
            :star
          elsif dash.empty?
            [range]
          else
            [first, last]
          end
          valid = (step.nil? || number?(step)) && (bounds == :star || bounds.all? { |value| value?(value, field) })
          return nil unless valid

          Item.new(bounds, step)
        end
      end

      def number?(text)
        text.match?(/\A[0-9]+\z/)
      end

      def value?(text, field)
        number?(text) || !name_value(text, field).nil?
      end

      def name_value(text, field)
        index = field.names.index(text.downcase(:ascii))
        index && index + field.min
      end

      def number(digits)
        digits.each_byte.reduce(0) { |n, digit| [n * 10 + digit - "0".ord, NUMBER_CAP].min }
      end

      def field_value(text, field)
        value = name_value(text, field) || number(text)
        unless value.between?(field.min, field.max)
          raise HronError.cron("#{field.name} must be #{field.min}-#{field.max}, got #{text}")
        end

        value
      end

      def day_expression(month_days, week_days)
        case [month_days, week_days]
        in [:any, :any]
          {of_week: DayFilterEvery.new}
        in [:any, {days:}]
          {of_week: weekday_filter(days)}
        in [:any, {nth:, weekday:}]
          {of_month: OrdinalWeekdayTarget.new(ORDINALS[nth - 1], weekday)}
        in [:any, {last:}]
          {of_month: OrdinalWeekdayTarget.new(OrdinalPosition::LAST, last)}
        in [{days:}, :any] if days.length == 31
          {of_week: DayFilterEvery.new}
        in [{days:}, :any]
          specs = runs(days.sort).map { |first, last| (first == last) ? SingleDay.new(first) : DayRange.new(first, last) }
          {of_month: DaysTarget.new(specs)}
        in [:last, :any]
          {of_month: LastDayTarget.new}
        in [:last_weekday, :any]
          {of_month: LastWeekdayTarget.new}
        in [{nearest:}, :any]
          {of_month: NearestWeekdayTarget.new(nearest, nil)}
        else
          raise HronError.cron(BOTH_DAYS_RESTRICTED)
        end
      end

      def weekday_filter(days)
        case days.sort
        in [0, 1, 2, 3, 4, 5, 6] then DayFilterEvery.new
        in [1, 2, 3, 4, 5] then DayFilterWeekday.new
        in [0, 6] then DayFilterWeekend.new
        else DayFilterDays.new(days.map { |d| WEEKDAYS[d] })
        end
      end

      def equal_gap(times)
        return nil if times.length < 2

        minutes = times.map { |t| minute_of_day(t) }
        gap = minutes[1] - minutes[0]
        equal = minutes.length >= 3 && minutes.each_cons(2).all? { |a, b| b - a == gap }
        equal ? gap : nil
      end

      def interval(times, gap, days)
        from = times.first
        last = times.last
        to = (from == MIDNIGHT && minute_of_day(last) + gap >= MINUTES_PER_DAY) ? END_OF_DAY : last
        interval, unit = (gap % 60).zero? ? [gap / 60, IntervalUnit::HOURS] : [gap, IntervalUnit::MIN]
        IntervalRepeat.new(interval, unit, from, to, days.is_a?(DayFilterEvery) ? nil : days)
      end

      def too_many_times(count, gap)
        return HronError.cron(INTERVAL_DAYS) if gap

        HronError.cron("not expressible in hron: #{count} times a day are too many to list")
      end

      def year_target(days, months)
        target = days[:of_month]
        return nil unless target && months.length == 1

        month = MonthName::ALL[months[0] - 1]
        case target
        in DaysTarget(specs: [SingleDay(day:)]) if day <= MonthName.max_day(month)
          YearDateTarget.new(month, day)
        in LastWeekdayTarget
          YearLastWeekdayTarget.new(month)
        in OrdinalWeekdayTarget(ordinal:, weekday:)
          YearOrdinalWeekdayTarget.new(ordinal, weekday, month)
        else
          nil
        end
      end

      def not_expressible(reason)
        HronError.cron("not expressible as cron: #{reason}")
      end

      def repeats_once(interval, unit)
        raise not_expressible("multi-#{unit} repeats not supported") if interval > 1
      end

      def day_fields(expr)
        case expr
        when IntervalRepeat
          ["*", expr.day_filter ? filter_field(expr.day_filter) : "*"]
        when DayRepeat
          repeats_once(expr.interval, "day")
          ["*", filter_field(expr.days)]
        when WeekRepeat
          repeats_once(expr.interval, "week")
          ["*", weekdays_field(expr.days)]
        when MonthRepeat
          repeats_once(expr.interval, "month")
          month_target_fields(expr.target)
        when YearRepeat
          repeats_once(expr.interval, "year")
          year_target_fields(expr.target)
        when SingleDateExpr
          raise not_expressible("ISO dates do not repeat") if expr.date.is_a?(IsoDate)

          [expr.date.day.to_s, "*"]
        end
      end

      def month_target_fields(target)
        case target
        when DaysTarget
          [list_field(Evaluator.days_of(target).sort.uniq, 31), "*"]
        when LastDayTarget
          ["L", "*"]
        when LastWeekdayTarget
          ["LW", "*"]
        when NearestWeekdayTarget
          raise not_expressible("directional nearest weekday not supported") if target.direction

          ["#{target.day}W", "*"]
        when OrdinalWeekdayTarget
          ["*", ordinal_field(target.ordinal, target.weekday)]
        end
      end

      def year_target_fields(target)
        case target
        when YearDateTarget, YearDayOfMonthTarget
          [target.day.to_s, "*"]
        when YearOrdinalWeekdayTarget
          ["*", ordinal_field(target.ordinal, target.weekday)]
        when YearLastWeekdayTarget
          ["LW", "*"]
        end
      end

      def month_field(schedule)
        during = schedule.during
        month = own_month(schedule.expression)
        if month
          raise not_expressible("during excludes the schedule's month") unless during.empty? || during.include?(month)

          MonthName.number(month).to_s
        elsif during.empty?
          "*"
        else
          list_field(during.map { |m| MonthName.number(m) }.sort.uniq, 12)
        end
      end

      def own_month(expr)
        case expr
        when YearRepeat then expr.target.month
        when SingleDateExpr then expr.date.is_a?(NamedDate) ? expr.date.month : nil
        end
      end

      def time_fields(expr)
        times = daily_times(expr)
        minutes = times.map { |t| t % 60 }.sort.uniq
        hours = times.map { |t| t / 60 }.sort.uniq
        if minutes.length * hours.length != times.length
          raise not_expressible("times are not every combination of their minutes and hours")
        end

        [step_field(minutes, 60), step_field(hours, 24)]
      end

      def daily_times(expr)
        times = if expr.is_a?(IntervalRepeat)
          Evaluator.interval_slots(expr.interval, expr.unit, expr.from_time, expr.to_time)
        else
          expr.times.map { |t| minute_of_day(t) }
        end
        times.sort.uniq
      end

      def filter_field(filter)
        case filter
        when DayFilterEvery then "*"
        when DayFilterWeekday then weekdays_field(Weekday::WEEKDAYS)
        when DayFilterWeekend then weekdays_field(Weekday::WEEKEND)
        when DayFilterDays then weekdays_field(filter.days)
        end
      end

      def weekdays_field(days)
        list_field(days.map { |d| Weekday.cron_dow(d) }.sort.uniq, 7)
      end

      def ordinal_field(ordinal, weekday)
        day = Weekday.cron_dow(weekday)
        (ordinal == OrdinalPosition::LAST) ? "#{day}L" : "#{day}##{OrdinalPosition.to_n(ordinal)}"
      end

      def step_field(values, size)
        first = values.first
        last = values.last
        gap = (values.length > 1) ? values[1] - first : nil
        equal_gaps = !gap.nil? && values.each_cons(2).all? { |a, b| b - a == gap }
        if values.length == size
          "*"
        elsif gap.nil?
          first.to_s
        elsif equal_gaps && first.zero? && last + gap == size
          "*/#{gap}"
        elsif equal_gaps && gap == 1
          "#{first}-#{last}"
        elsif equal_gaps && values.length >= 3
          "#{first}-#{last}/#{gap}"
        else
          list_field(values, size)
        end
      end

      def list_field(values, size)
        return "*" if values.length == size

        runs(values).map { |first, last| (first == last) ? first.to_s : "#{first}-#{last}" }.join(",")
      end

      def runs(sorted_values)
        sorted_values.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
      end

      def minute_of_day(time)
        time.hour * 60 + time.minute
      end
    end
  end
end
