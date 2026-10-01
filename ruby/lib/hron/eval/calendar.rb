# frozen_string_literal: true

require "date"
require_relative "../ast"

module Hron
  class Evaluator
    # Date arithmetic on the proleptic Gregorian calendar, so a search that reaches back
    # before 1582 stays on the same calendar: no time zones, no schedules.
    module Calendar
      FRIDAY = 5
      SATURDAY = 6
      SUNDAY = 7

      module_function

      # The date, or nil when the month has no such day.
      def date(year, month, day)
        Date.new(year, month, day, Date::GREGORIAN) if Date.valid_date?(year, month, day, Date::GREGORIAN)
      end

      def parse_date(iso)
        Date.iso8601(iso, Date::GREGORIAN)
      end

      def days_between(from, to)
        to.jd - from.jd
      end

      # Months since January of year 0.
      def month_index(date)
        (date.year * 12) + date.month - 1
      end

      def first_of_month(index)
        year, month = index.divmod(12)
        Date.new(year, month + 1, 1, Date::GREGORIAN)
      end

      def first_of_year(year)
        Date.new(year, 1, 1, Date::GREGORIAN)
      end

      def monday_of_week(date)
        date - (date.cwday - 1)
      end

      def matches_day_filter?(date, filter)
        case filter
        when DayFilterEvery then true
        when DayFilterWeekday then date.cwday <= FRIDAY
        when DayFilterWeekend then date.cwday > FRIDAY
        when DayFilterDays then filter.days.any? { |day| Weekday.number(day) == date.cwday }
        end
      end

      # The dates a monthly target names in a month, earliest first.
      def month_target_dates(year, month, target)
        case target
        when DaysTarget
          Hron.expand_month_target(target).uniq.sort.filter_map { |day| date(year, month, day) }
        when LastDayTarget then [last_day_of_month(year, month)]
        when LastWeekdayTarget then [last_weekday_of_month(year, month)]
        when NearestWeekdayTarget then [nearest_weekday(year, month, target.day, target.direction)].compact
        when OrdinalWeekdayTarget then [ordinal_weekday(year, month, target.ordinal, target.weekday)].compact
        end
      end

      def year_target_date(year, target)
        month = MonthName.number(target.month)
        case target
        when YearDateTarget, YearDayOfMonthTarget then date(year, month, target.day)
        when YearOrdinalWeekdayTarget then ordinal_weekday(year, month, target.ordinal, target.weekday)
        when YearLastWeekdayTarget then last_weekday_of_month(year, month)
        end
      end

      def last_day_of_month(year, month)
        Date.new(year, month, -1, Date::GREGORIAN)
      end

      # The last Monday to Friday of a month.
      def last_weekday_of_month(year, month)
        last = last_day_of_month(year, month)
        last - [last.cwday - FRIDAY, 0].max
      end

      # The nth given weekday of a month, or its last for OrdinalPosition::LAST; nil when
      # the month has no nth.
      def ordinal_weekday(year, month, ordinal, weekday)
        target = Weekday.number(weekday)
        if ordinal == OrdinalPosition::LAST
          last = last_day_of_month(year, month)
          return last - ((last.cwday - target) % 7)
        end

        first = Date.new(year, month, 1, Date::GREGORIAN)
        nth = first + (((target - first.cwday) % 7) + (7 * (OrdinalPosition.to_n(ordinal) - 1)))
        nth if nth.month == month
      end

      # The weekday nearest day of a month, or nil when the month is shorter. Without a
      # direction it stays in the month, as cron's W does; with one it can cross into the
      # adjacent month (spec/README.md, "Nearest weekday and `during`").
      def nearest_weekday(year, month, day, toward)
        target = date(year, month, day)
        return target if target.nil? || target.cwday <= FRIDAY

        target + case [target.cwday, toward]
        in [SATURDAY, NearestDirection::NEXT] then 2
        in [SATURDAY, NearestDirection::PREVIOUS] then -1
        in [SATURDAY, nil] if day == 1 then 2
        in [SATURDAY, nil] then -1
        in [SUNDAY, NearestDirection::NEXT] then 1
        in [SUNDAY, NearestDirection::PREVIOUS] then -2
        in [SUNDAY, nil] if target == last_day_of_month(year, month) then -2
        in [SUNDAY, nil] then 1
        end
      end
    end
  end
end
