# frozen_string_literal: true

require "date"
require_relative "ast"
require_relative "error"
require_relative "display"
require_relative "parser"

module Hron
  # The checks of spec/README.md, "Schedules built in code", in its order. A part of the wrong
  # Ruby type is a TypeError, a usage error rather than a HronError. Names are Symbols, so a
  # name of another type is a TypeError too; the AST's unions (expression, day filter, ...)
  # have no Ruby type of their own, so any value outside one is an unknown value of its kind.
  # checked builds every part anew as its Hron class, so a part of a subclass gives a schedule
  # equal to the parsed one.
  module Parts
    INTERVAL_MAX = 2_147_483_647

    module_function

    def checked(data)
      raise TypeError, "data must be a Hron::ScheduleData, not #{data.class}" unless data.is_a?(ScheduleData)

      expr = check_expression(data.expression)
      except = list(data.except, "except").map { |exception| check_exception(exception) }
      until_spec = data.until.nil? ? nil : check_until(data.until)
      starting = data.starting.nil? ? nil : check_iso_date(string(data.starting, "starting"))
      during = list(data.during, "during").map { |month| check_name(month, MonthName::ALL, "month") }
      timezone = data.timezone.nil? ? nil : check_timezone(string(data.timezone, "timezone"))
      if until_spec.is_a?(NamedUntil) && starting.nil?
        raise error("until #{until_spec.month} #{until_spec.day} has no year: add a starting date, or use an ISO date")
      end
      ScheduleData.new(expression: expr, timezone:, except:, until: until_spec, starting:, during:)
    end

    def check_expression(expr)
      case expr
      when IntervalRepeat
        interval = check_interval(expr.interval)
        unit = check_name(expr.unit, IntervalUnit::ALL, "interval unit")
        from = check_time(expr.from_time)
        to = check_time(expr.to_time)
        if minute_of_day(from) > minute_of_day(to)
          raise error("time window must not run backwards: #{from} to #{to} (a window cannot cross midnight)")
        end
        day_filter = expr.day_filter.nil? ? nil : check_day_filter(expr.day_filter)
        IntervalRepeat.new(interval, unit, from, to, day_filter)
      when DayRepeat
        interval = check_interval(expr.interval)
        # `every 2 days` has no place for a day filter, so other days would not survive display.
        raise error("days must be every day when the interval is above 1") if interval > 1 && !expr.days.is_a?(DayFilterEvery)

        DayRepeat.new(interval, check_day_filter(expr.days), check_times(expr.times))
      when WeekRepeat
        interval = check_interval(expr.interval)
        WeekRepeat.new(interval, check_weekdays(expr.days), check_times(expr.times))
      when MonthRepeat
        interval = check_interval(expr.interval)
        MonthRepeat.new(interval, check_month_target(expr.target), check_times(expr.times))
      when SingleDateExpr
        SingleDateExpr.new(check_date(expr.date), check_times(expr.times))
      when YearRepeat
        interval = check_interval(expr.interval)
        YearRepeat.new(interval, check_year_target(expr.target), check_times(expr.times))
      else
        raise unknown("expression", expr)
      end
    end

    def check_interval(interval)
      integer(interval, "interval")
      raise error("interval must be 1-#{INTERVAL_MAX}, got #{interval}") unless interval.between?(1, INTERVAL_MAX)

      interval
    end

    def check_times(times)
      raise error("times must not be empty") if list(times, "times").empty?

      times.map { |time| check_time(time) }
    end

    def check_time(time)
      raise TypeError, "a time must be a Hron::TimeOfDay, not #{time.class}" unless time.is_a?(TimeOfDay)

      integer(time.hour, "hour")
      integer(time.minute, "minute")
      raise error("time must be 00:00-23:59, got #{time}") unless time.hour.between?(0, 23) && time.minute.between?(0, 59)

      TimeOfDay.new(time.hour, time.minute)
    end

    def minute_of_day(time)
      (time.hour * 60) + time.minute
    end

    def check_day_filter(filter)
      case filter
      when DayFilterEvery then DayFilterEvery.new
      when DayFilterWeekday then DayFilterWeekday.new
      when DayFilterWeekend then DayFilterWeekend.new
      when DayFilterDays then DayFilterDays.new(check_weekdays(filter.days))
      else raise unknown("day filter", filter)
      end
    end

    def check_weekdays(days)
      raise error("days must not be empty") if list(days, "days").empty?

      days.map { |day| check_name(day, Weekday::ALL, "weekday") }
    end

    def check_month_target(target)
      case target
      when DaysTarget
        raise error("days must not be empty") if list(target.specs, "days").empty?

        DaysTarget.new(target.specs.map { |spec| check_day_spec(spec) })
      when LastDayTarget then LastDayTarget.new
      when LastWeekdayTarget then LastWeekdayTarget.new
      when NearestWeekdayTarget
        direction = target.direction.nil? ? nil : check_name(target.direction, NearestDirection::ALL, "direction")
        check_day(target.day, suffixed: true)
        NearestWeekdayTarget.new(target.day, direction)
      when OrdinalWeekdayTarget
        ordinal = check_name(target.ordinal, OrdinalPosition::ALL, "ordinal")
        OrdinalWeekdayTarget.new(ordinal, check_name(target.weekday, Weekday::ALL, "weekday"))
      else
        raise unknown("month target", target)
      end
    end

    def check_day_spec(spec)
      case spec
      when SingleDay
        check_day(spec.day, suffixed: true)
        SingleDay.new(spec.day)
      when DayRange
        start = check_day(spec.start, suffixed: true)
        last = check_day(spec.end_day, suffixed: true)
        raise error("day range must not run backwards: #{start} to #{last}") if spec.start > spec.end_day

        DayRange.new(spec.start, spec.end_day)
      else
        raise unknown("day spec", spec)
      end
    end

    def check_year_target(target)
      case target
      when YearDateTarget then YearDateTarget.new(*check_named_date(target.month, target.day))
      when YearOrdinalWeekdayTarget
        ordinal = check_name(target.ordinal, OrdinalPosition::ALL, "ordinal")
        weekday = check_name(target.weekday, Weekday::ALL, "weekday")
        YearOrdinalWeekdayTarget.new(ordinal, weekday, check_name(target.month, MonthName::ALL, "month"))
      when YearDayOfMonthTarget
        month = check_name(target.month, MonthName::ALL, "month")
        shown = check_day(target.day, suffixed: true)
        check_day_in_month(target.day, month, shown)
        YearDayOfMonthTarget.new(target.day, month)
      when YearLastWeekdayTarget then YearLastWeekdayTarget.new(check_name(target.month, MonthName::ALL, "month"))
      else raise unknown("year target", target)
      end
    end

    def check_date(date)
      case date
      when NamedDate then NamedDate.new(*check_named_date(date.month, date.day))
      when IsoDate then IsoDate.new(check_iso_date(string(date.date, "date")))
      else raise unknown("date", date)
      end
    end

    def check_exception(exception)
      case exception
      when NamedException then NamedException.new(*check_named_date(exception.month, exception.day))
      when IsoException then IsoException.new(check_iso_date(string(exception.date, "date")))
      else raise unknown("exception", exception)
      end
    end

    def check_until(until_spec)
      case until_spec
      when NamedUntil then NamedUntil.new(*check_named_date(until_spec.month, until_spec.day))
      when IsoUntil then IsoUntil.new(check_iso_date(string(until_spec.date, "date")))
      else raise unknown("until", until_spec)
      end
    end

    def check_named_date(month, day)
      check_name(month, MonthName::ALL, "month")
      shown = check_day(day, suffixed: false)
      check_day_in_month(day, month, shown)
      [month, day]
    end

    def check_day(day, suffixed:)
      integer(day, "day")
      shown = suffixed ? "#{day}#{Display.ordinal_suffix(day)}" : day.to_s
      raise error("day must be 1-31, got #{shown}") unless day.between?(1, 31)

      shown
    end

    def check_day_in_month(day, month, shown)
      max = MonthName.max_day(month)
      raise error("day must be 1-#{max} for #{month}, got #{shown}") if day > max
    end

    # Date.iso8601 alone would also read `20260206`, `+002026-02-06` and fullwidth digits. The
    # encoding must be ASCII-compatible, or ten bytes that read as a date are other characters.
    def check_iso_date(date)
      if date.encoding.ascii_compatible? && date.b.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        year, month, day = date.b.split("-").map(&:to_i)
        return date if year >= 1 && Date.valid_date?(year, month, day, Date::GREGORIAN)
      end

      raise error("date must be a calendar date from 0001-01-01 to 9999-12-31, got #{Utf8.convert(date)}")
    end

    def check_timezone(name)
      Parser.iana_timezone(name) or
        raise error("timezone must be UTC or an Area/Location name such as America/New_York, got #{Utf8.convert(name)}")
    end

    def check_name(value, names, kind)
      raise TypeError, "#{kind} must be a Symbol, not #{value.class}" unless value.is_a?(Symbol)
      raise unknown(kind, value) unless names.include?(value)

      value
    end

    def integer(value, what)
      raise TypeError, "#{what} must be an Integer, not #{value.class}" unless value.is_a?(Integer)
    end

    def string(value, what)
      raise TypeError, "#{what} must be a String, not #{value.class}" unless value.is_a?(String)

      String.new(value)
    end

    def list(value, what)
      raise TypeError, "#{what} must be an Array, not #{value.class}" unless value.is_a?(Array)

      value
    end

    def unknown(kind, value)
      error("unknown #{kind} #{value.inspect}")
    end

    def error(message)
      HronError.eval(message)
    end
  end
end
