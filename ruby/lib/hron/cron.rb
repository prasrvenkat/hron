# frozen_string_literal: true

require_relative "ast"
require_relative "error"

module Hron
  # Cron conversion module
  module Cron
    CRON_DOW_MAP = {
      0 => Weekday::SUNDAY,
      1 => Weekday::MONDAY,
      2 => Weekday::TUESDAY,
      3 => Weekday::WEDNESDAY,
      4 => Weekday::THURSDAY,
      5 => Weekday::FRIDAY,
      6 => Weekday::SATURDAY,
      7 => Weekday::SUNDAY
    }.freeze

    def self.to_cron(schedule)
      raise HronError.cron("not expressible as cron (except clauses not supported)") unless schedule.except.empty?

      raise HronError.cron("not expressible as cron (until clauses not supported)") if schedule.until

      raise HronError.cron("not expressible as cron (during clauses not supported)") unless schedule.during.empty?

      expr = schedule.expr

      case expr
      when DayRepeat
        raise HronError.cron("not expressible as cron (multi-day intervals not supported)") if expr.interval > 1
        raise HronError.cron("not expressible as cron (multiple times not supported)") if expr.times.length != 1

        time = expr.times[0]
        dow = day_filter_to_cron_dow(expr.days)
        "#{time.minute} #{time.hour} * * #{dow}"

      when IntervalRepeat
        full_day = expr.from_time.hour.zero? && expr.from_time.minute.zero? &&
          expr.to_time.hour == 23 && expr.to_time.minute == 59
        raise HronError.cron("not expressible as cron (partial-day interval windows not supported)") unless full_day

        raise HronError.cron("not expressible as cron (interval with day filter not supported)") if expr.day_filter

        if expr.unit == IntervalUnit::MIN
          if (60 % expr.interval) != 0
            raise HronError.cron("not expressible as cron (*/#{expr.interval} breaks at hour boundaries)")
          end

          "*/#{expr.interval} * * * *"
        else
          "0 */#{expr.interval} * * *"
        end

      when WeekRepeat
        raise HronError.cron("not expressible as cron (multi-week intervals not supported)")

      when MonthRepeat
        raise HronError.cron("not expressible as cron (multi-month intervals not supported)") if expr.interval > 1
        raise HronError.cron("not expressible as cron (multiple times not supported)") if expr.times.length != 1

        time = expr.times[0]
        case expr.target
        when DaysTarget
          expanded = []
          expr.target.specs.each do |s|
            case s
            when SingleDay
              expanded << s.day
            when DayRange
              (s.start..s.end_day).each { |d| expanded << d }
            end
          end
          dom = expanded.join(",")
          "#{time.minute} #{time.hour} #{dom} * *"
        when LastDayTarget
          raise HronError.cron("not expressible as cron (last day of month not supported)")
        else
          raise HronError.cron("not expressible as cron (last weekday of month not supported)")
        end

      when OrdinalRepeat
        raise HronError.cron("not expressible as cron (ordinal weekday of month not supported)")

      when SingleDateExpr
        raise HronError.cron("not expressible as cron (single dates are not repeating)")

      when YearRepeat
        raise HronError.cron("not expressible as cron (yearly schedules not supported in 5-field cron)")

      else
        raise HronError.cron("unknown expression type: #{expr.class}")
      end
    end

    def self.day_filter_to_cron_dow(filter)
      case filter
      when DayFilterEvery
        "*"
      when DayFilterWeekday
        "1-5"
      when DayFilterWeekend
        "0,6"
      when DayFilterDays
        nums = filter.days.map { |d| Weekday.cron_dow(d) }.sort
        nums.join(",")
      end
    end

    DOW_NAME_MAP = {
      "SUN" => 0, "MON" => 1, "TUE" => 2, "WED" => 3,
      "THU" => 4, "FRI" => 5, "SAT" => 6
    }.freeze

    MONTH_NAME_MAP = {
      "JAN" => 1, "FEB" => 2, "MAR" => 3, "APR" => 4,
      "MAY" => 5, "JUN" => 6, "JUL" => 7, "AUG" => 8,
      "SEP" => 9, "OCT" => 10, "NOV" => 11, "DEC" => 12
    }.freeze

    def self.from_cron(cron_str)
      cron_str = cron_str.strip

      # Handle @ shortcuts first
      return parse_cron_shortcut(cron_str) if cron_str.start_with?("@")

      fields = cron_str.split
      raise HronError.cron("expected 5 cron fields, got #{fields.length}") if fields.length != 5

      minute_field, hour_field, dom_field, month_field, dow_field = fields

      # Normalize ? to * (they're semantically equivalent for our purposes)
      dom_field = "*" if dom_field == "?"
      dow_field = "*" if dow_field == "?"

      # Parse month field into during clause
      during = parse_month_field(month_field)

      # Check for special DOW patterns: nth weekday (#), last weekday (5L)
      result = try_parse_nth_weekday(minute_field, hour_field, dom_field, dow_field, during)
      return result if result

      # Check for L (last day) or LW (last weekday) in DOM
      result = try_parse_last_day(minute_field, hour_field, dom_field, dow_field, during)
      return result if result

      # Check for W (nearest weekday) - not yet supported
      if dom_field.end_with?("W") && dom_field != "LW"
        raise HronError.cron("W (nearest weekday) not yet supported")
      end

      # Check for interval patterns: */N or range/N
      result = try_parse_interval(minute_field, hour_field, dom_field, dow_field, during)
      return result if result

      # Standard time-based cron
      minute = parse_single_value(minute_field, "minute", 0, 59)
      hour = parse_single_value(hour_field, "hour", 0, 23)
      time = TimeOfDay.new(hour, minute)

      # DOM-based (monthly) - when DOM is specified and DOW is *
      if dom_field != "*" && dow_field == "*"
        target = parse_dom_field(dom_field)
        return ScheduleData.new(
          expr: MonthRepeat.new(1, target, [time]),
          during: during
        )
      end

      # DOW-based (day repeat)
      days = parse_cron_dow(dow_field)
      ScheduleData.new(
        expr: DayRepeat.new(1, days, [time]),
        during: during
      )
    end

    # Parse @ shortcuts like @daily, @hourly, etc.
    def self.parse_cron_shortcut(cron_str)
      case cron_str.downcase
      when "@yearly", "@annually"
        ScheduleData.new(
          expr: YearRepeat.new(
            1,
            YearDateTarget.new(MonthName::JAN, 1),
            [TimeOfDay.new(0, 0)]
          )
        )
      when "@monthly"
        ScheduleData.new(
          expr: MonthRepeat.new(
            1,
            DaysTarget.new([SingleDay.new(1)]),
            [TimeOfDay.new(0, 0)]
          )
        )
      when "@weekly"
        ScheduleData.new(
          expr: DayRepeat.new(
            1,
            DayFilterDays.new([Weekday::SUNDAY]),
            [TimeOfDay.new(0, 0)]
          )
        )
      when "@daily", "@midnight"
        ScheduleData.new(
          expr: DayRepeat.new(
            1,
            DayFilterEvery.new,
            [TimeOfDay.new(0, 0)]
          )
        )
      when "@hourly"
        ScheduleData.new(
          expr: IntervalRepeat.new(
            1,
            IntervalUnit::HOURS,
            TimeOfDay.new(0, 0),
            TimeOfDay.new(23, 59),
            nil
          )
        )
      else
        raise HronError.cron("unknown @ shortcut: #{cron_str}")
      end
    end

    # Parse month field into a Vec<MonthName> for the `during` clause.
    def self.parse_month_field(field)
      return [] if field == "*"

      months = []
      field.split(",").each do |part|
        # Check for step values FIRST (e.g., 1-12/3 or */3)
        if part.include?("/")
          range_part, step_str = part.split("/", 2)
          if range_part == "*"
            start_num = 1
            end_num = 12
          elsif range_part.include?("-")
            s, e = range_part.split("-", 2)
            start_num = MonthName.number(parse_month_value(s))
            end_num = MonthName.number(parse_month_value(e))
          else
            raise HronError.cron("invalid month step expression: #{part}")
          end

          step = begin
            Integer(step_str)
          rescue
            raise(HronError.cron("invalid month step value: #{step_str}"))
          end
          raise HronError.cron("step cannot be 0") if step == 0

          n = start_num
          while n <= end_num
            months << month_from_number(n)
            n += step
          end
        elsif part.include?("-")
          # Range like 1-3 or JAN-MAR
          start_str, end_str = part.split("-", 2)
          start_month = parse_month_value(start_str)
          end_month = parse_month_value(end_str)
          start_num = MonthName.number(start_month)
          end_num = MonthName.number(end_month)
          raise HronError.cron("invalid month range: #{start_str} > #{end_str}") if start_num > end_num

          (start_num..end_num).each { |n| months << month_from_number(n) }
        else
          # Single month
          months << parse_month_value(part)
        end
      end

      months
    end

    # Parse a single month value (number 1-12 or name JAN-DEC).
    def self.parse_month_value(s)
      # Try as number first
      if /^\d+$/.match?(s)
        n = Integer(s)
        return month_from_number(n)
      end
      # Try as name
      n = MONTH_NAME_MAP[s.upcase]
      raise HronError.cron("invalid month: #{s}") unless n

      month_from_number(n)
    end

    def self.month_from_number(n)
      month = MonthName.from_number(n)
      raise HronError.cron("invalid month number: #{n}") unless month

      month
    end

    # Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday).
    def self.try_parse_nth_weekday(minute_field, hour_field, dom_field, dow_field, during)
      # Check for # pattern (nth weekday of month)
      if dow_field.include?("#")
        dow_str, nth_str = dow_field.split("#", 2)
        dow_num = parse_dow_value(dow_str)
        weekday = cron_dow_to_weekday(dow_num)
        nth = begin
          Integer(nth_str)
        rescue
          raise(HronError.cron("invalid nth value: #{nth_str}"))
        end
        raise HronError.cron("nth must be 1-5, got #{nth}") if nth < 1 || nth > 5

        ordinal = case nth
        when 1 then OrdinalPosition::FIRST
        when 2 then OrdinalPosition::SECOND
        when 3 then OrdinalPosition::THIRD
        when 4 then OrdinalPosition::FOURTH
        when 5 then OrdinalPosition::FIFTH
        end

        raise HronError.cron("DOM must be * when using # for nth weekday") if dom_field != "*" && dom_field != "?"

        minute = parse_single_value(minute_field, "minute", 0, 59)
        hour = parse_single_value(hour_field, "hour", 0, 23)

        return ScheduleData.new(
          expr: OrdinalRepeat.new(1, ordinal, weekday, [TimeOfDay.new(hour, minute)]),
          during: during
        )
      end

      # Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
      if dow_field.end_with?("L") && dow_field.length > 1
        dow_str = dow_field[0..-2]
        dow_num = parse_dow_value(dow_str)
        weekday = cron_dow_to_weekday(dow_num)

        raise HronError.cron("DOM must be * when using nL for last weekday") if dom_field != "*" && dom_field != "?"

        minute = parse_single_value(minute_field, "minute", 0, 59)
        hour = parse_single_value(hour_field, "hour", 0, 23)

        return ScheduleData.new(
          expr: OrdinalRepeat.new(1, OrdinalPosition::LAST, weekday, [TimeOfDay.new(hour, minute)]),
          during: during
        )
      end

      nil
    end

    # Try to parse L (last day) or LW (last weekday) patterns.
    def self.try_parse_last_day(minute_field, hour_field, dom_field, dow_field, during)
      return nil unless dom_field == "L" || dom_field == "LW"

      raise HronError.cron("DOW must be * when using L or LW in DOM") if dow_field != "*" && dow_field != "?"

      minute = parse_single_value(minute_field, "minute", 0, 59)
      hour = parse_single_value(hour_field, "hour", 0, 23)

      target = (dom_field == "LW") ? LastWeekdayTarget.new : LastDayTarget.new

      ScheduleData.new(
        expr: MonthRepeat.new(1, target, [TimeOfDay.new(hour, minute)]),
        during: during
      )
    end

    # Try to parse interval patterns: */N, range/N in minute or hour fields.
    def self.try_parse_interval(minute_field, hour_field, dom_field, dow_field, during)
      # Minute interval: */N or range/N
      if minute_field.include?("/")
        range_part, step_str = minute_field.split("/", 2)
        interval = begin
          Integer(step_str)
        rescue
          raise(HronError.cron("invalid minute interval value"))
        end
        raise HronError.cron("step cannot be 0") if interval == 0

        if range_part == "*"
          from_minute = 0
          to_minute = 59
        elsif range_part.include?("-")
          s, e = range_part.split("-", 2)
          from_minute = begin
            Integer(s)
          rescue
            raise(HronError.cron("invalid minute range"))
          end
          to_minute = begin
            Integer(e)
          rescue
            raise(HronError.cron("invalid minute range"))
          end
          raise HronError.cron("range start must be <= end: #{s}-#{e}") if from_minute > to_minute
        else
          # Single value with step (e.g., 0/15) - treat as starting point
          from_minute = begin
            Integer(range_part)
          rescue
            raise(HronError.cron("invalid minute value"))
          end
          to_minute = 59
        end

        # Determine the hour window
        if hour_field == "*"
          from_hour = 0
          to_hour = 23
        elsif hour_field.include?("-")
          s, e = hour_field.split("-", 2)
          from_hour = begin
            Integer(s)
          rescue
            raise(HronError.cron("invalid hour range"))
          end
          to_hour = begin
            Integer(e)
          rescue
            raise(HronError.cron("invalid hour range"))
          end
        elsif hour_field.include?("/")
          # Hour also has step - this is complex, handle as hour interval
          return nil
        else
          h = begin
            Integer(hour_field)
          rescue
            raise(HronError.cron("invalid hour"))
          end
          from_hour = h
          to_hour = h
        end

        # Check if this should be a day filter
        day_filter = (dow_field == "*") ? nil : parse_cron_dow(dow_field)

        if dom_field == "*" || dom_field == "?"
          # Determine the end minute based on context
          end_minute = if from_minute == 0 && to_minute == 59 && to_hour == 23
            # Full day: 00:00 to 23:59
            59
          elsif from_minute == 0 && to_minute == 59
            # Partial day with full minutes range: use :00 for cleaner output
            0
          else
            to_minute
          end

          return ScheduleData.new(
            expr: IntervalRepeat.new(
              interval,
              IntervalUnit::MIN,
              TimeOfDay.new(from_hour, from_minute),
              TimeOfDay.new(to_hour, end_minute),
              day_filter
            ),
            during: during
          )
        end
      end

      # Hour interval: 0 */N or 0 range/N
      if hour_field.include?("/") && (minute_field == "0" || minute_field == "00")
        range_part, step_str = hour_field.split("/", 2)
        interval = begin
          Integer(step_str)
        rescue
          raise(HronError.cron("invalid hour interval value"))
        end
        raise HronError.cron("step cannot be 0") if interval == 0

        if range_part == "*"
          from_hour = 0
          to_hour = 23
        elsif range_part.include?("-")
          s, e = range_part.split("-", 2)
          from_hour = begin
            Integer(s)
          rescue
            raise(HronError.cron("invalid hour range"))
          end
          to_hour = begin
            Integer(e)
          rescue
            raise(HronError.cron("invalid hour range"))
          end
          raise HronError.cron("range start must be <= end: #{s}-#{e}") if from_hour > to_hour
        else
          from_hour = begin
            Integer(range_part)
          rescue
            raise(HronError.cron("invalid hour value"))
          end
          to_hour = 23
        end

        if (dom_field == "*" || dom_field == "?") && (dow_field == "*" || dow_field == "?")
          # Use :59 only for full day (00:00 to 23:59), otherwise use :00
          end_minute = (from_hour == 0 && to_hour == 23) ? 59 : 0

          return ScheduleData.new(
            expr: IntervalRepeat.new(
              interval,
              IntervalUnit::HOURS,
              TimeOfDay.new(from_hour, 0),
              TimeOfDay.new(to_hour, end_minute),
              nil
            ),
            during: during
          )
        end
      end

      nil
    end

    # Parse a DOM field into a MonthTarget.
    def self.parse_dom_field(field)
      specs = []

      field.split(",").each do |part|
        if part.include?("/")
          # Step value: 1-31/2 or */5
          range_part, step_str = part.split("/", 2)
          if range_part == "*"
            start_day = 1
            end_day = 31
          elsif range_part.include?("-")
            s, e = range_part.split("-", 2)
            start_day = begin
              Integer(s)
            rescue
              raise(HronError.cron("invalid DOM range start: #{s}"))
            end
            end_day = begin
              Integer(e)
            rescue
              raise(HronError.cron("invalid DOM range end: #{e}"))
            end
            raise HronError.cron("range start must be <= end: #{start_day}-#{end_day}") if start_day > end_day
          else
            start_day = begin
              Integer(range_part)
            rescue
              raise(HronError.cron("invalid DOM value: #{range_part}"))
            end
            end_day = 31
          end

          step = begin
            Integer(step_str)
          rescue
            raise(HronError.cron("invalid DOM step: #{step_str}"))
          end
          raise HronError.cron("step cannot be 0") if step == 0

          validate_dom(start_day)
          validate_dom(end_day)

          d = start_day
          while d <= end_day
            specs << SingleDay.new(d)
            d += step
          end
        elsif part.include?("-")
          # Range: 1-5
          start_str, end_str = part.split("-", 2)
          start_day = begin
            Integer(start_str)
          rescue
            raise(HronError.cron("invalid DOM range start: #{start_str}"))
          end
          end_day = begin
            Integer(end_str)
          rescue
            raise(HronError.cron("invalid DOM range end: #{end_str}"))
          end
          raise HronError.cron("range start must be <= end: #{start_day}-#{end_day}") if start_day > end_day
          validate_dom(start_day)
          validate_dom(end_day)
          specs << DayRange.new(start_day, end_day)
        else
          # Single: 15
          day = begin
            Integer(part)
          rescue
            raise(HronError.cron("invalid DOM value: #{part}"))
          end
          validate_dom(day)
          specs << SingleDay.new(day)
        end
      end

      DaysTarget.new(specs)
    end

    def self.validate_dom(day)
      raise HronError.cron("DOM must be 1-31, got #{day}") if day < 1 || day > 31
    end

    # Parse a DOW field into a DayFilter.
    def self.parse_cron_dow(field)
      return DayFilterEvery.new if field == "*"

      days = []

      field.split(",").each do |part|
        if part.include?("/")
          # Step value: 0-6/2 or */2
          range_part, step_str = part.split("/", 2)
          if range_part == "*"
            start_dow = 0
            end_dow = 6
          elsif range_part.include?("-")
            s, e = range_part.split("-", 2)
            start_dow = parse_dow_value_raw(s)
            end_dow = parse_dow_value_raw(e)
            raise HronError.cron("range start must be <= end: #{s}-#{e}") if start_dow > end_dow
          else
            start_dow = parse_dow_value_raw(range_part)
            end_dow = 6
          end

          step = begin
            Integer(step_str)
          rescue
            raise(HronError.cron("invalid DOW step: #{step_str}"))
          end
          raise HronError.cron("step cannot be 0") if step == 0

          d = start_dow
          while d <= end_dow
            days << cron_dow_to_weekday(d)
            d += step
          end
        elsif part.include?("-")
          # Range: 1-5 or MON-FRI
          # Parse without normalizing 7 to 0 for range purposes
          start_str, end_str = part.split("-", 2)
          start_dow = parse_dow_value_raw(start_str)
          end_dow = parse_dow_value_raw(end_str)
          raise HronError.cron("range start must be <= end: #{start_str}-#{end_str}") if start_dow > end_dow

          (start_dow..end_dow).each do |d|
            # Normalize 7 to 0 (Sunday) when converting to weekday
            normalized = (d == 7) ? 0 : d
            days << cron_dow_to_weekday(normalized)
          end
        else
          # Single: 1 or MON
          dow = parse_dow_value(part)
          days << cron_dow_to_weekday(dow)
        end
      end

      # Check for special patterns
      if days.length == 5
        sorted = days.sort_by { |d| Weekday.number(d) }
        return DayFilterWeekday.new if sorted == Weekday::WEEKDAYS
      end
      if days.length == 2
        sorted = days.sort_by { |d| Weekday.number(d) }
        return DayFilterWeekend.new if sorted == Weekday::WEEKEND
      end

      DayFilterDays.new(days)
    end

    # Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0.
    def self.parse_dow_value(s)
      raw = parse_dow_value_raw(s)
      # Normalize 7 to 0 (both mean Sunday)
      (raw == 7) ? 0 : raw
    end

    # Parse a DOW value without normalizing 7 to 0 (for range checking).
    def self.parse_dow_value_raw(s)
      # Try as number first
      if /^\d+$/.match?(s)
        n = Integer(s)
        raise HronError.cron("DOW must be 0-7, got #{n}") if n > 7

        return n
      end
      # Try as name
      n = DOW_NAME_MAP[s.upcase]
      raise HronError.cron("invalid DOW: #{s}") unless n

      n
    end

    def self.cron_dow_to_weekday(n)
      result = CRON_DOW_MAP[n]
      raise HronError.cron("invalid DOW number: #{n}") unless result

      result
    end

    # Parse a single numeric value with validation.
    def self.parse_single_value(field, name, min, max)
      value = begin
        Integer(field)
      rescue
        raise(HronError.cron("invalid #{name} field: #{field}"))
      end
      raise HronError.cron("#{name} must be #{min}-#{max}, got #{value}") if value < min || value > max

      value
    end
  end
end
