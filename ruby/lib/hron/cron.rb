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

    def self.from_cron(cron_str)
      fields = cron_str.strip.split
      raise HronError.cron("expected 5 cron fields, got #{fields.length}") if fields.length != 5

      minute_field, hour_field, dom_field, _month_field, dow_field = fields

      # Minute interval: */N
      if minute_field.start_with?("*/")
        interval_str = minute_field[2..]
        begin
          interval = Integer(interval_str)
        rescue ArgumentError
          raise HronError.cron("invalid minute interval")
        end

        from_hour = 0
        to_hour = 23

        if hour_field == "*"
          # full day
        elsif hour_field.include?("-")
          parts = hour_field.split("-")
          begin
            from_hour = Integer(parts[0])
            to_hour = Integer(parts[1])
          rescue ArgumentError, IndexError
            raise HronError.cron("invalid hour range")
          end
        else
          begin
            h = Integer(hour_field)
          rescue ArgumentError
            raise HronError.cron("invalid hour")
          end
          from_hour = h
          to_hour = h
        end

        day_filter = (dow_field == "*") ? nil : parse_cron_dow(dow_field)

        if dom_field == "*"
          return ScheduleData.new(
            expr: IntervalRepeat.new(
              interval,
              IntervalUnit::MIN,
              TimeOfDay.new(from_hour, 0),
              TimeOfDay.new(to_hour, (to_hour == 23) ? 59 : 0),
              day_filter
            )
          )
        end
      end

      # Hour interval: 0 */N
      if hour_field.start_with?("*/") && minute_field == "0"
        interval_str = hour_field[2..]
        begin
          interval = Integer(interval_str)
        rescue ArgumentError
          raise HronError.cron("invalid hour interval")
        end
        if dom_field == "*" && dow_field == "*"
          return ScheduleData.new(
            expr: IntervalRepeat.new(
              interval,
              IntervalUnit::HOURS,
              TimeOfDay.new(0, 0),
              TimeOfDay.new(23, 59),
              nil
            )
          )
        end
      end

      # Standard time-based cron
      begin
        minute = Integer(minute_field)
      rescue ArgumentError
        raise HronError.cron("invalid minute field: #{minute_field}")
      end
      begin
        hour = Integer(hour_field)
      rescue ArgumentError
        raise HronError.cron("invalid hour field: #{hour_field}")
      end
      t = TimeOfDay.new(hour, minute)

      # DOM-based (monthly)
      if dom_field != "*" && dow_field == "*"
        raise HronError.cron("DOM ranges not supported: #{dom_field}") if dom_field.include?("-")

        day_nums = []
        dom_field.split(",").each do |s|
          begin
            n = Integer(s)
          rescue ArgumentError
            raise HronError.cron("invalid DOM field: #{dom_field}")
          end
          day_nums << n
        end
        specs = day_nums.map { |d| SingleDay.new(d) }
        return ScheduleData.new(
          expr: MonthRepeat.new(1, DaysTarget.new(specs), [t])
        )
      end

      # DOW-based (day repeat)
      days = parse_cron_dow(dow_field)
      expr = DayRepeat.new(1, days, [t])
      ScheduleData.new(expr: expr)
    end

    def self.parse_cron_dow(field)
      return DayFilterEvery.new if field == "*"
      return DayFilterWeekday.new if field == "1-5"
      return DayFilterWeekend.new if ["0,6", "6,0"].include?(field)

      raise HronError.cron("DOW ranges not supported: #{field}") if field.include?("-")

      nums = []
      field.split(",").each do |s|
        begin
          n = Integer(s)
        rescue ArgumentError
          raise HronError.cron("invalid DOW field: #{field}")
        end
        nums << n
      end

      days = nums.map { |n| cron_dow_to_weekday(n) }
      DayFilterDays.new(days)
    end

    def self.cron_dow_to_weekday(n)
      result = CRON_DOW_MAP[n]
      raise HronError.cron("invalid DOW number: #{n}") unless result

      result
    end
  end
end
