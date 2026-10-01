# frozen_string_literal: true

require "date"
require "tzinfo"
require_relative "ast"
require_relative "error"
require_relative "lexer"

module Hron
  class Parser
    # The `{what}` of each `expected {what}, got ...` error, one per phrase in the position table
    # of spec/README.md, "Parse errors".
    module Expected
      EVERY_OR_ON = "'every' or 'on'"
      REPEATER = "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number"
      UNIT = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')"
      AT = "'at'"
      TIME = "a time (HH:MM)"
      FROM = "'from'"
      TO = "'to'"
      DAY_TARGET = "'day', 'weekday', 'weekend' or a day name"
      ON = "'on'"
      DAY_NAME = "a day name"
      THE = "'the'"
      MONTH_TARGET = "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'"
      MONTH_LAST = "'day', 'weekday' or a day name"
      NEAREST = "'nearest'"
      WEEKDAY = "'weekday'"
      DAY_OF_MONTH = "a day such as 15th"
      YEAR_TARGET = "a month name or 'the'"
      YEAR_THE = "a day such as 15th, 'last' or an ordinal such as 'first'"
      YEAR_LAST = "'weekday' or a day name"
      OF = "'of'"
      MONTH_NAME = "a month name"
      DAY_NUMBER = "a day number"
      DATE = "a date (YYYY-MM-DD, or a month and day)"
      ISO_DATE = "a date (YYYY-MM-DD)"
      TIMEZONE = "a timezone"
    end

    CLAUSE_ORDER = [
      [TokenKind::EXCEPT, "except"],
      [TokenKind::UNTIL, "until"],
      [TokenKind::STARTING, "starting"],
      [TokenKind::DURING, "during"],
      [TokenKind::IN, "in"]
    ].freeze

    MONTH_LENGTHS = Hash.new(31).merge(
      MonthName::FEB => 29, MonthName::APR => 30, MonthName::JUN => 30, MonthName::SEP => 30, MonthName::NOV => 30
    ).freeze
    private_constant :Expected, :CLAUSE_ORDER, :MONTH_LENGTHS

    # Timezone names match in any case (spec/README.md, "Parse-time validation").
    def self.iana_names
      @iana_names ||= TZInfo::Timezone.all_identifiers.to_h { |id| [id.downcase(:ascii), id] }
    end

    def initialize(tokens, input)
      @tokens = tokens
      @pos = 0
      @input = input
      @chars = Utf8.convert(input).chars
      @until_span = nil
    end

    def parse
      schedule = parse_clauses(parse_expression)
      raise leftover(schedule) if peek

      # spec/README.md, "Parse errors": every other error wins over a named until without starting.
      check_named_until(schedule)
      schedule
    end

    private

    def peek
      @tokens[@pos]
    end

    def peek_kind
      peek&.kind
    end

    def advance
      token = @tokens[@pos]
      @pos += 1
      token
    end

    def previous
      @tokens[@pos - 1]
    end

    def eat(kind)
      found = peek_kind == kind
      @pos += 1 if found
      found
    end

    def expect(kind, what)
      raise expected(what) unless eat(kind)
    end

    def text(token)
      @chars[token.span.start...token.span.end_pos].join
    end

    def error(message, start, stop, suggestion: nil)
      HronError.parse(message, Span.new(start, stop), @input, suggestion: suggestion)
    end

    def token_error(message, token)
      error(message, token.span.start, token.span.end_pos)
    end

    def expected(what)
      token = peek
      return token_error("expected #{what}, got '#{text(token)}'", token) if token

      stop = @tokens.last&.span&.end_pos || 0
      error("expected #{what}, got end of input", stop, stop)
    end

    def parse_expression
      if eat(TokenKind::EVERY)
        parse_every
      elsif eat(TokenKind::ON)
        parse_on
      else
        raise expected(Expected::EVERY_OR_ON)
      end
    end

    def parse_clauses(expr)
      fields = {expr: expr}
      fields[:except] = parse_exception_list if eat(TokenKind::EXCEPT)

      if peek_kind == TokenKind::UNTIL
        until_token = advance
        date = parse_date
        fields[:until] = date.is_a?(IsoDate) ? IsoUntil.new(date.date) : NamedUntil.new(date.month, date.day)
        @until_span = [until_token.span.start, previous.span.end_pos]
      end

      if eat(TokenKind::STARTING)
        raise expected(Expected::ISO_DATE) unless peek_kind.is_a?(TIsoDate)

        fields[:anchor] = iso_date(advance)
      end

      fields[:during] = parse_month_list if eat(TokenKind::DURING)

      if eat(TokenKind::IN)
        raise expected(Expected::TIMEZONE) unless peek_kind.is_a?(TTimezone)

        fields[:timezone] = timezone(advance)
      end

      ScheduleData.new(**fields)
    end

    def leftover(schedule)
      token = peek
      # Every clause holds at least one item, so a clause was read exactly when its field is set.
      read = [schedule.except.any?, !schedule.until.nil?, !schedule.anchor.nil?, schedule.during.any?, !schedule.timezone.nil?]
      clause = CLAUSE_ORDER.index { |kind, _| kind == token.kind }
      last_read = read.rindex(true)
      message = if clause && read[clause]
        "duplicate '#{CLAUSE_ORDER[clause][1]}' clause"
      elsif clause && last_read
        "'#{CLAUSE_ORDER[clause][1]}' must come before '#{CLAUSE_ORDER[last_read][1]}'"
      else
        "unexpected '#{text(token)}' after the schedule"
      end
      token_error(message, token)
    end

    def check_named_until(schedule)
      named = schedule.until
      return unless named.is_a?(NamedUntil) && schedule.anchor.nil?

      raise error(
        "until #{named.month} #{named.day} has no year: add a starting date, or use an ISO date",
        *@until_span,
        suggestion: "until #{named.month} #{named.day} starting YYYY-MM-DD"
      )
    end

    def parse_exception_list
      exceptions = [parse_exception]
      exceptions << parse_exception while eat(TokenKind::COMMA)
      exceptions
    end

    def parse_exception
      date = parse_date
      date.is_a?(IsoDate) ? IsoException.new(date.date) : NamedException.new(date.month, date.day)
    end

    def parse_date
      kind = peek_kind
      if kind.is_a?(TIsoDate)
        iso_date(advance)
        IsoDate.new(kind.date)
      elsif kind.is_a?(TMonthName)
        advance
        NamedDate.new(kind.name, parse_day_of(kind.name))
      else
        raise expected(Expected::DATE)
      end
    end

    def iso_date(token)
      written = text(token)
      year, month, day = written.split("-").map(&:to_i)
      return written if year >= 1 && Date.valid_date?(year, month, day, Date::GREGORIAN)

      raise token_error("date must be a calendar date from 0001-01-01 to 9999-12-31, got #{written}", token)
    end

    # spec/README.md, "Parse-time validation": `UTC` or an IANA Area/Location name in any case,
    # stored with the database's capitalization.
    def timezone(token)
      name = text(token)
      lower = name.downcase(:ascii)
      # System zoneinfo directories that are not IANA names of their own.
      legacy = lower.start_with?("systemv/", "posix/", "right/")
      if name.ascii_only? && !legacy
        return "UTC" if lower == "utc"

        canonical = name.include?("/") && Parser.iana_names[lower]
        return canonical if canonical
      end
      raise token_error("timezone must be UTC or an Area/Location name such as America/New_York, got #{name}", token)
    end

    def parse_every
      kind = peek_kind
      case kind
      when TokenKind::DAY
        advance
        parse_day_repeat(1, DayFilterEvery.new)
      when TokenKind::WEEKDAY_KW
        advance
        parse_day_repeat(1, DayFilterWeekday.new)
      when TokenKind::WEEKEND_KW
        advance
        parse_day_repeat(1, DayFilterWeekend.new)
      when TDayName
        parse_day_repeat(1, DayFilterDays.new(parse_day_list))
      when TokenKind::WEEKS
        advance
        parse_week_repeat(1)
      when TokenKind::MONTH
        advance
        parse_month_repeat(1)
      when TokenKind::YEAR
        advance
        parse_year_repeat(1)
      when TNumber
        parse_number_repeat(kind.value)
      else
        raise expected(Expected::REPEATER)
      end
    end

    def parse_day_repeat(interval, days)
      expect(TokenKind::AT, Expected::AT)
      DayRepeat.new(interval, days, parse_time_list)
    end

    def parse_number_repeat(interval)
      number = advance
      raise token_error("interval must be 1-2147483647, got #{text(number)}", number) if interval.zero?

      kind = peek_kind
      case kind
      when TokenKind::WEEKS
        advance
        parse_week_repeat(interval)
      when TIntervalUnit
        advance
        parse_interval_repeat(interval, kind.unit)
      when TokenKind::DAY
        advance
        parse_day_repeat(interval, DayFilterEvery.new)
      when TokenKind::MONTH
        advance
        parse_month_repeat(interval)
      when TokenKind::YEAR
        advance
        parse_year_repeat(interval)
      else
        raise expected(Expected::UNIT)
      end
    end

    def parse_interval_repeat(interval, unit)
      expect(TokenKind::FROM, Expected::FROM)
      from = parse_time
      from_token = previous
      expect(TokenKind::TO, Expected::TO)
      to = parse_time
      to_token = previous
      if (from.hour * 60) + from.minute > (to.hour * 60) + to.minute
        raise error(
          "time window must not run backwards: #{text(from_token)} to #{text(to_token)} (a window cannot cross midnight)",
          from_token.span.start, to_token.span.end_pos
        )
      end

      day_filter = eat(TokenKind::ON) ? parse_day_target : nil
      IntervalRepeat.new(interval, unit, from, to, day_filter)
    end

    def parse_week_repeat(interval)
      expect(TokenKind::ON, Expected::ON)
      days = parse_day_list
      expect(TokenKind::AT, Expected::AT)
      WeekRepeat.new(interval, days, parse_time_list)
    end

    def parse_month_repeat(interval)
      expect(TokenKind::ON, Expected::ON)
      expect(TokenKind::THE, Expected::THE)

      kind = peek_kind
      target = if kind == TokenKind::LAST
        advance
        parse_month_last_target
      elsif kind.is_a?(TOrdinal)
        advance
        OrdinalWeekdayTarget.new(kind.position, parse_day_name)
      elsif kind.is_a?(TOrdinalNumber)
        DaysTarget.new(parse_ordinal_day_list)
      elsif [TokenKind::NEXT, TokenKind::PREVIOUS, TokenKind::NEAREST].include?(kind)
        parse_nearest_weekday_target
      else
        raise expected(Expected::MONTH_TARGET)
      end

      expect(TokenKind::AT, Expected::AT)
      MonthRepeat.new(interval, target, parse_time_list)
    end

    def parse_month_last_target
      kind = peek_kind
      target = if kind == TokenKind::DAY
        LastDayTarget.new
      elsif kind == TokenKind::WEEKDAY_KW
        LastWeekdayTarget.new
      elsif kind.is_a?(TDayName)
        OrdinalWeekdayTarget.new(OrdinalPosition::LAST, kind.name)
      else
        raise expected(Expected::MONTH_LAST)
      end
      advance
      target
    end

    def parse_nearest_weekday_target
      direction = if eat(TokenKind::NEXT)
        NearestDirection::NEXT
      elsif eat(TokenKind::PREVIOUS)
        NearestDirection::PREVIOUS
      end
      expect(TokenKind::NEAREST, Expected::NEAREST)
      expect(TokenKind::WEEKDAY_KW, Expected::WEEKDAY)
      expect(TokenKind::TO, Expected::TO)
      day, = parse_ordinal_day
      NearestWeekdayTarget.new(day, direction)
    end

    def parse_ordinal_day_list
      specs = [parse_ordinal_day_spec]
      specs << parse_ordinal_day_spec while eat(TokenKind::COMMA)
      specs
    end

    def parse_ordinal_day_spec
      start, start_token = parse_ordinal_day
      return SingleDay.new(start) unless eat(TokenKind::TO)

      stop, stop_token = parse_ordinal_day
      if start > stop
        raise error(
          "day range must not run backwards: #{text(start_token)} to #{text(stop_token)}",
          start_token.span.start, stop_token.span.end_pos
        )
      end
      DayRange.new(start, stop)
    end

    def parse_ordinal_day
      kind = peek_kind
      raise expected(Expected::DAY_OF_MONTH) unless kind.is_a?(TOrdinalNumber)

      token = advance
      [day_of_month(kind.value, token), token]
    end

    def parse_day_of(month)
      kind = peek_kind
      raise expected(Expected::DAY_NUMBER) unless kind.is_a?(TNumber) || kind.is_a?(TOrdinalNumber)

      token = advance
      day = day_of_month(kind.value, token)
      check_day_in_month(day, token, month)
      day
    end

    def day_of_month(n, token)
      return n if n.between?(1, 31)

      raise token_error("day must be 1-31, got #{text(token)}", token)
    end

    def check_day_in_month(day, token, month)
      max = MONTH_LENGTHS[month]
      raise token_error("day must be 1-#{max} for #{month}, got #{text(token)}", token) if day > max
    end

    def parse_year_repeat(interval)
      expect(TokenKind::ON, Expected::ON)

      kind = peek_kind
      target = if kind == TokenKind::THE
        advance
        parse_year_target_after_the
      elsif kind.is_a?(TMonthName)
        advance
        YearDateTarget.new(kind.name, parse_day_of(kind.name))
      else
        raise expected(Expected::YEAR_TARGET)
      end

      expect(TokenKind::AT, Expected::AT)
      YearRepeat.new(interval, target, parse_time_list)
    end

    def parse_year_target_after_the
      kind = peek_kind
      if kind == TokenKind::LAST
        advance
        parse_year_last_target
      elsif kind.is_a?(TOrdinal)
        advance
        weekday = parse_day_name
        YearOrdinalWeekdayTarget.new(kind.position, weekday, parse_of_month)
      elsif kind.is_a?(TOrdinalNumber)
        day, day_token = parse_ordinal_day
        month = parse_of_month
        check_day_in_month(day, day_token, month)
        YearDayOfMonthTarget.new(day, month)
      else
        raise expected(Expected::YEAR_THE)
      end
    end

    def parse_year_last_target
      kind = peek_kind
      if kind == TokenKind::WEEKDAY_KW
        advance
        YearLastWeekdayTarget.new(parse_of_month)
      elsif kind.is_a?(TDayName)
        advance
        YearOrdinalWeekdayTarget.new(OrdinalPosition::LAST, kind.name, parse_of_month)
      else
        raise expected(Expected::YEAR_LAST)
      end
    end

    def parse_of_month
      expect(TokenKind::OF, Expected::OF)
      parse_month_name
    end

    def parse_month_name
      kind = peek_kind
      raise expected(Expected::MONTH_NAME) unless kind.is_a?(TMonthName)

      advance
      kind.name
    end

    def parse_month_list
      months = [parse_month_name]
      months << parse_month_name while eat(TokenKind::COMMA)
      months
    end

    def parse_on
      date = parse_date
      expect(TokenKind::AT, Expected::AT)
      SingleDateExpr.new(date, parse_time_list)
    end

    def parse_day_target
      case peek_kind
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
        DayFilterDays.new(parse_day_list)
      else
        raise expected(Expected::DAY_TARGET)
      end
    end

    def parse_day_name
      kind = peek_kind
      raise expected(Expected::DAY_NAME) unless kind.is_a?(TDayName)

      advance
      kind.name
    end

    def parse_day_list
      days = [parse_day_name]
      days << parse_day_name while eat(TokenKind::COMMA)
      days
    end

    def parse_time_list
      times = [parse_time]
      times << parse_time while eat(TokenKind::COMMA)
      times
    end

    def parse_time
      kind = peek_kind
      raise expected(Expected::TIME) unless kind.is_a?(TTime)

      advance
      TimeOfDay.new(kind.hour, kind.minute)
    end
  end

  def self.parse(input)
    tokens = tokenize(input)
    raise HronError.parse("empty expression", Span.new(0, 0), input) if tokens.empty?

    Parser.new(tokens, input).parse
  end
end
