# frozen_string_literal: true

require "date"
require_relative "ast"
require_relative "error"
require_relative "lexer"

module Hron
  # Parser for hron expressions
  class Parser
    def initialize(tokens, input)
      @tokens = tokens
      @pos = 0
      @input = input
    end

    def peek
      (@pos < @tokens.length) ? @tokens[@pos] : nil
    end

    def peek_kind
      tok = peek
      tok&.kind
    end

    def advance
      tok = peek
      @pos += 1 if tok
      tok
    end

    def current_span
      tok = peek
      return tok.span if tok

      if @tokens.any?
        last = @tokens.last
        Span.new(last.span.end_pos, last.span.end_pos)
      else
        Span.new(0, 0)
      end
    end

    def error(message, span)
      HronError.parse(message, span, @input)
    end

    def error_at_end(message)
      if @tokens.any?
        end_pos = @tokens.last.span.end_pos
        span = Span.new(end_pos, end_pos)
      else
        span = Span.new(0, 0)
      end
      HronError.parse(message, span, @input)
    end

    def consume(expected, check_class)
      span = current_span
      tok = peek
      if tok && tok.kind.is_a?(check_class)
        @pos += 1
        return tok
      end
      raise error("expected #{expected}, got #{tok.kind.class.name.split("::").last}", span) if tok

      raise error_at_end("expected #{expected}")
    end

    def consume_keyword(expected, kind_symbol)
      span = current_span
      tok = peek
      if tok && tok.kind == kind_symbol
        @pos += 1
        return tok
      end
      raise error("expected #{expected}", span) if tok

      raise error_at_end("expected #{expected}")
    end

    # --- Grammar productions ---

    def parse_expression
      span = current_span
      kind = peek_kind

      case kind
      when TokenKind::EVERY
        advance
        expr = parse_every
      when TokenKind::ON
        advance
        expr = parse_on
      when TOrdinal, TokenKind::LAST
        expr = parse_ordinal_repeat
      else
        raise error("expected 'every', 'on', or an ordinal (first, second, ...)", span)
      end

      parse_trailing_clauses(expr)
    end

    def parse_trailing_clauses(expr)
      schedule = ScheduleData.new(expr: expr)

      # except
      if peek_kind == TokenKind::EXCEPT
        advance
        schedule = ScheduleData.new(
          expr: schedule.expr,
          timezone: schedule.timezone,
          except: parse_exception_list,
          until: schedule.until,
          anchor: schedule.anchor,
          during: schedule.during
        )
      end

      # until
      if peek_kind == TokenKind::UNTIL
        advance
        schedule = ScheduleData.new(
          expr: schedule.expr,
          timezone: schedule.timezone,
          except: schedule.except,
          until: parse_until_spec,
          anchor: schedule.anchor,
          during: schedule.during
        )
      end

      # starting
      if peek_kind == TokenKind::STARTING
        advance
        k = peek_kind
        raise error("expected ISO date (YYYY-MM-DD) after 'starting'", current_span) unless k.is_a?(TIsoDate)

        validate_iso_date(k.date)
        anchor = k.date
        advance
        schedule = ScheduleData.new(
          expr: schedule.expr,
          timezone: schedule.timezone,
          except: schedule.except,
          until: schedule.until,
          anchor: anchor,
          during: schedule.during
        )

      end

      # during
      if peek_kind == TokenKind::DURING
        advance
        schedule = ScheduleData.new(
          expr: schedule.expr,
          timezone: schedule.timezone,
          except: schedule.except,
          until: schedule.until,
          anchor: schedule.anchor,
          during: parse_month_list
        )
      end

      # in <timezone>
      if peek_kind == TokenKind::IN
        advance
        k = peek_kind
        raise error("expected timezone after 'in'", current_span) unless k.is_a?(TTimezone)

        tz = k.tz
        advance
        schedule = ScheduleData.new(
          expr: schedule.expr,
          timezone: tz,
          except: schedule.except,
          until: schedule.until,
          anchor: schedule.anchor,
          during: schedule.during
        )

      end

      schedule
    end

    def parse_exception_list
      exceptions = [parse_exception]
      while peek_kind == TokenKind::COMMA
        advance
        exceptions << parse_exception
      end
      exceptions
    end

    def validate_iso_date(date_str)
      Date.iso8601(date_str)
    rescue Date::Error
      raise error("invalid date: #{date_str}", current_span)
    end

    def parse_exception
      k = peek_kind
      if k.is_a?(TIsoDate)
        validate_iso_date(k.date)
        advance
        return IsoException.new(k.date)
      end
      if k.is_a?(TMonthName)
        month = k.name
        advance
        day = parse_day_number("expected day number after month name in exception")
        return NamedException.new(month, day)
      end
      raise error("expected ISO date or month-day in exception", current_span)
    end

    def parse_until_spec
      k = peek_kind
      if k.is_a?(TIsoDate)
        validate_iso_date(k.date)
        advance
        return IsoUntil.new(k.date)
      end
      if k.is_a?(TMonthName)
        month = k.name
        advance
        day = parse_day_number("expected day number after month name in until")
        return NamedUntil.new(month, day)
      end
      raise error("expected ISO date or month-day after 'until'", current_span)
    end

    def parse_day_number(error_msg)
      k = peek_kind
      if k.is_a?(TNumber)
        advance
        return k.value
      end
      if k.is_a?(TOrdinalNumber)
        advance
        return k.value
      end
      raise error(error_msg, current_span)
    end

    # After "every": dispatch
    def parse_every
      raise error_at_end("expected repeater") unless peek

      k = peek_kind

      case k
      when TokenKind::YEAR
        advance
        parse_year_repeat(1)
      when TokenKind::DAY
        parse_day_repeat(1, DayFilterEvery.new)
      when TokenKind::WEEKDAY_KW
        advance
        parse_day_repeat(1, DayFilterWeekday.new)
      when TokenKind::WEEKEND_KW
        advance
        parse_day_repeat(1, DayFilterWeekend.new)
      when TDayName
        days = parse_day_list
        parse_day_repeat(1, DayFilterDays.new(days))
      when TokenKind::MONTH
        advance
        parse_month_repeat(1)
      when TNumber
        parse_number_repeat
      else
        raise error(
          "expected day, weekday, weekend, year, day name, month, or number after 'every'",
          current_span
        )
      end
    end

    def parse_day_repeat(interval, days)
      consume_keyword("'day'", TokenKind::DAY) if days.is_a?(DayFilterEvery)
      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list
      DayRepeat.new(interval, days, times)
    end

    def parse_number_repeat
      span = current_span
      k = peek_kind
      num = k.value
      raise error("interval must be at least 1", span) if num.zero?

      advance

      nk = peek_kind
      case nk
      when TokenKind::WEEKS
        advance
        parse_week_repeat(num)
      when TIntervalUnit
        parse_interval_repeat(num)
      when TokenKind::DAY
        parse_day_repeat(num, DayFilterEvery.new)
      when TokenKind::MONTH
        advance
        parse_month_repeat(num)
      when TokenKind::YEAR
        advance
        parse_year_repeat(num)
      else
        raise error(
          "expected 'weeks', 'min', 'minutes', 'hour', 'hours', 'day(s)', 'month(s)', or 'year(s)' after number",
          current_span
        )
      end
    end

    def parse_interval_repeat(interval)
      k = peek_kind
      unit = k.unit
      advance

      consume_keyword("'from'", TokenKind::FROM)
      from_time = parse_time
      consume_keyword("'to'", TokenKind::TO)
      to_time = parse_time

      day_filter = nil
      if peek_kind == TokenKind::ON
        advance
        day_filter = parse_day_target
      end

      IntervalRepeat.new(interval, unit, from_time, to_time, day_filter)
    end

    def parse_week_repeat(interval)
      consume_keyword("'on'", TokenKind::ON)
      days = parse_day_list
      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list
      WeekRepeat.new(interval, days, times)
    end

    def parse_month_repeat(interval)
      consume_keyword("'on'", TokenKind::ON)
      consume_keyword("'the'", TokenKind::THE)

      k = peek_kind

      if k == TokenKind::LAST
        advance
        nk = peek_kind
        if nk == TokenKind::DAY
          advance
          target = LastDayTarget.new
        elsif nk == TokenKind::WEEKDAY_KW
          advance
          target = LastWeekdayTarget.new
        else
          raise error("expected 'day' or 'weekday' after 'last'", current_span)
        end
      elsif k.is_a?(TOrdinalNumber)
        specs = parse_ordinal_day_list
        target = DaysTarget.new(specs)
      elsif k == TokenKind::NEXT || k == TokenKind::PREVIOUS || k == TokenKind::NEAREST
        target = parse_nearest_weekday_target
      else
        raise error("expected ordinal day (1st, 15th), 'last', or '[next|previous] nearest' after 'the'", current_span)
      end

      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list
      MonthRepeat.new(interval, target, times)
    end

    def parse_ordinal_repeat
      ordinal = parse_ordinal_position

      k = peek_kind
      raise error("expected day name after ordinal", current_span) unless k.is_a?(TDayName)

      day = k.name
      advance

      consume_keyword("'of'", TokenKind::OF)
      consume_keyword("'every'", TokenKind::EVERY)

      # "of every [N] month(s) at ..."
      interval = 1
      nk = peek_kind
      if nk.is_a?(TNumber)
        interval = nk.value
        raise error("interval must be at least 1", current_span) if interval.zero?

        advance
      end

      consume_keyword("'month'", TokenKind::MONTH)
      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list

      OrdinalRepeat.new(interval, ordinal, day, times)
    end

    def parse_year_repeat(interval)
      consume_keyword("'on'", TokenKind::ON)

      k = peek_kind

      if k == TokenKind::THE
        advance
        target = parse_year_target_after_the
      elsif k.is_a?(TMonthName)
        month = k.name
        advance
        day = parse_day_number("expected day number after month name")
        target = YearDateTarget.new(month, day)
      else
        raise error("expected month name or 'the' after 'every year on'", current_span)
      end

      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list
      YearRepeat.new(interval, target, times)
    end

    def parse_year_target_after_the
      k = peek_kind

      if k == TokenKind::LAST
        advance
        nk = peek_kind
        if nk == TokenKind::WEEKDAY_KW
          advance
          consume_keyword("'of'", TokenKind::OF)
          month = parse_month_name_token
          return YearLastWeekdayTarget.new(month)
        end
        if nk.is_a?(TDayName)
          weekday = nk.name
          advance
          consume_keyword("'of'", TokenKind::OF)
          month = parse_month_name_token
          return YearOrdinalWeekdayTarget.new(OrdinalPosition::LAST, weekday, month)
        end
        raise error("expected 'weekday' or day name after 'last' in yearly expression", current_span)
      end

      if k.is_a?(TOrdinal)
        ordinal = parse_ordinal_position
        nk = peek_kind
        if nk.is_a?(TDayName)
          weekday = nk.name
          advance
          consume_keyword("'of'", TokenKind::OF)
          month = parse_month_name_token
          return YearOrdinalWeekdayTarget.new(ordinal, weekday, month)
        end
        raise error("expected day name after ordinal in yearly expression", current_span)
      end

      if k.is_a?(TOrdinalNumber)
        day = k.value
        advance
        consume_keyword("'of'", TokenKind::OF)
        month = parse_month_name_token
        return YearDayOfMonthTarget.new(day, month)
      end

      raise error("expected ordinal, day number, or 'last' after 'the' in yearly expression", current_span)
    end

    def parse_month_name_token
      k = peek_kind
      if k.is_a?(TMonthName)
        advance
        return k.name
      end
      raise error("expected month name", current_span)
    end

    def parse_ordinal_position
      span = current_span
      k = peek_kind
      if k.is_a?(TOrdinal)
        advance
        return k.position
      end
      if k == TokenKind::LAST
        advance
        return OrdinalPosition::LAST
      end
      raise error("expected ordinal (first, second, third, fourth, fifth, last)", span)
    end

    def parse_on
      date = parse_date_target
      consume_keyword("'at'", TokenKind::AT)
      times = parse_time_list
      SingleDateExpr.new(date, times)
    end

    def parse_date_target
      k = peek_kind
      if k.is_a?(TIsoDate)
        validate_iso_date(k.date)
        advance
        return IsoDate.new(k.date)
      end
      if k.is_a?(TMonthName)
        month = k.name
        advance
        day = parse_day_number("expected day number after month name")
        return NamedDate.new(month, day)
      end
      raise error("expected date (ISO date or month name)", current_span)
    end

    def parse_day_target
      k = peek_kind
      case k
      when TokenKind::DAY
        advance
        DayFilterEvery.new
      when TokenKind::WEEKDAY_KW
        advance
        DayFilterWeekday.new
      when TokenKind::WEEKEND_KW
        advance
        DayFilterWeekend.new
      when TDayName
        days = parse_day_list
        DayFilterDays.new(days)
      else
        raise error("expected 'day', 'weekday', 'weekend', or day name", current_span)
      end
    end

    def parse_day_list
      k = peek_kind
      raise error("expected day name", current_span) unless k.is_a?(TDayName)

      days = [k.name]
      advance

      while peek_kind == TokenKind::COMMA
        advance
        nk = peek_kind
        raise error("expected day name after ','", current_span) unless nk.is_a?(TDayName)

        days << nk.name
        advance
      end
      days
    end

    def parse_ordinal_day_list
      specs = [parse_ordinal_day_spec]
      while peek_kind == TokenKind::COMMA
        advance
        specs << parse_ordinal_day_spec
      end
      specs
    end

    def parse_ordinal_day_spec
      k = peek_kind
      raise error("expected ordinal day number", current_span) unless k.is_a?(TOrdinalNumber)

      start = k.value
      advance

      if peek_kind == TokenKind::TO
        advance
        nk = peek_kind
        raise error("expected ordinal day number after 'to'", current_span) unless nk.is_a?(TOrdinalNumber)

        end_day = nk.value
        advance
        return DayRange.new(start, end_day)
      end

      SingleDay.new(start)
    end

    def parse_nearest_weekday_target
      k = peek_kind

      # Optional direction: "next" or "previous"
      direction = nil
      if k == TokenKind::NEXT
        advance
        direction = NearestDirection::NEXT
      elsif k == TokenKind::PREVIOUS
        advance
        direction = NearestDirection::PREVIOUS
      end

      consume_keyword("'nearest'", TokenKind::NEAREST)
      consume_keyword("'weekday'", TokenKind::WEEKDAY_KW)
      consume_keyword("'to'", TokenKind::TO)

      # Parse the day number (ordinal like 15th)
      k = peek_kind
      if k.is_a?(TOrdinalNumber)
        day = k.value
        advance
      else
        raise error("expected ordinal day number after 'to'", current_span)
      end

      NearestWeekdayTarget.new(day, direction)
    end

    def parse_month_list
      months = [parse_month_name_token]
      while peek_kind == TokenKind::COMMA
        advance
        months << parse_month_name_token
      end
      months
    end

    def parse_time_list
      times = [parse_time]
      while peek_kind == TokenKind::COMMA
        advance
        times << parse_time
      end
      times
    end

    def parse_time
      span = current_span
      k = peek_kind
      if k.is_a?(TTime)
        advance
        return TimeOfDay.new(k.hour, k.minute)
      end
      raise error("expected time (HH:MM)", span)
    end
  end

  def self.parse(input)
    tokens = tokenize(input)

    raise HronError.parse("empty expression", Span.new(0, 0), input) if tokens.empty?

    parser = Parser.new(tokens, input)
    schedule = parser.parse_expression

    raise HronError.parse("unexpected tokens after expression", parser.current_span, input) if parser.peek

    schedule
  end
end
