# frozen_string_literal: true

require_relative "ast"

module Hron
  # Display module for converting schedules to canonical string representation
  module Display
    def self.display(schedule)
      out = display_expr(schedule.expr)

      unless schedule.except.empty?
        parts = schedule.except.map do |exc|
          case exc
          when NamedException
            "#{exc.month} #{exc.day}"
          when IsoException
            exc.date
          else
            raise "unknown exception type: #{exc.class}"
          end
        end
        out += " except #{parts.join(", ")}"
      end

      if schedule.until
        case schedule.until
        when IsoUntil
          out += " until #{schedule.until.date}"
        when NamedUntil
          out += " until #{schedule.until.month} #{schedule.until.day}"
        else
          raise "unknown until type: #{schedule.until.class}"
        end
      end

      out += " starting #{schedule.anchor}" if schedule.anchor

      out += " during #{schedule.during.join(", ")}" unless schedule.during.empty?

      out += " in #{schedule.timezone}" if schedule.timezone

      out
    end

    def self.display_expr(expr)
      case expr
      when IntervalRepeat
        out = "every #{expr.interval} #{unit_display(expr.interval, expr.unit)}"
        out += " from #{expr.from_time} to #{expr.to_time}"
        out += " on #{display_day_filter(expr.day_filter)}" if expr.day_filter
        out

      when DayRepeat
        if expr.interval > 1
          "every #{expr.interval} days at #{format_time_list(expr.times)}"
        else
          "every #{display_day_filter(expr.days)} at #{format_time_list(expr.times)}"
        end

      when WeekRepeat
        day_str = expr.days.join(", ")
        "every #{expr.interval} weeks on #{day_str} at #{format_time_list(expr.times)}"

      when MonthRepeat
        target_str = case expr.target
        when DaysTarget
          format_ordinal_day_specs(expr.target.specs)
        when LastDayTarget
          "last day"
        when LastWeekdayTarget
          "last weekday"
        when NearestWeekdayTarget
          prefix = case expr.target.direction
          when NearestDirection::NEXT
            "next "
          when NearestDirection::PREVIOUS
            "previous "
          else
            ""
          end
          day = expr.target.day
          "#{prefix}nearest weekday to #{day}#{ordinal_suffix(day)}"
        when OrdinalWeekdayTarget
          "#{expr.target.ordinal} #{expr.target.weekday}"
        else
          raise "unknown month target: #{expr.target.class}"
        end
        if expr.interval > 1
          "every #{expr.interval} months on the #{target_str} at #{format_time_list(expr.times)}"
        else
          "every month on the #{target_str} at #{format_time_list(expr.times)}"
        end

      when SingleDateExpr
        date_str = case expr.date
        when NamedDate
          "#{expr.date.month} #{expr.date.day}"
        when IsoDate
          expr.date.date
        else
          raise "unknown date type: #{expr.date.class}"
        end
        "on #{date_str} at #{format_time_list(expr.times)}"

      when YearRepeat
        target_str = case expr.target
        when YearDateTarget
          "#{expr.target.month} #{expr.target.day}"
        when YearOrdinalWeekdayTarget
          "the #{expr.target.ordinal} #{expr.target.weekday} of #{expr.target.month}"
        when YearDayOfMonthTarget
          "the #{expr.target.day}#{ordinal_suffix(expr.target.day)} of #{expr.target.month}"
        when YearLastWeekdayTarget
          "the last weekday of #{expr.target.month}"
        else
          raise "unknown year target: #{expr.target.class}"
        end
        if expr.interval > 1
          "every #{expr.interval} years on #{target_str} at #{format_time_list(expr.times)}"
        else
          "every year on #{target_str} at #{format_time_list(expr.times)}"
        end

      else
        raise "unknown expression type: #{expr.class}"
      end
    end

    def self.display_day_filter(filter)
      case filter
      when DayFilterEvery
        "day"
      when DayFilterWeekday
        "weekday"
      when DayFilterWeekend
        "weekend"
      when DayFilterDays
        filter.days.join(", ")
      else
        raise "unknown day filter: #{filter.class}"
      end
    end

    def self.format_time_list(times)
      times.map(&:to_s).join(", ")
    end

    def self.format_ordinal_day_specs(specs)
      parts = specs.map do |spec|
        case spec
        when SingleDay
          "#{spec.day}#{ordinal_suffix(spec.day)}"
        when DayRange
          "#{spec.start}#{ordinal_suffix(spec.start)} to #{spec.end_day}#{ordinal_suffix(spec.end_day)}"
        end
      end
      parts.join(", ")
    end

    def self.ordinal_suffix(n)
      mod100 = n % 100
      return "th" if mod100.between?(11, 13)

      case n % 10
      when 1
        "st"
      when 2
        "nd"
      when 3
        "rd"
      else
        "th"
      end
    end

    def self.unit_display(interval, unit)
      if unit == IntervalUnit::MIN
        (interval == 1) ? "minute" : "min"
      else
        (interval == 1) ? "hour" : "hours"
      end
    end
  end
end
