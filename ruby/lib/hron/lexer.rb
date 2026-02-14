# frozen_string_literal: true

require_relative "ast"
require_relative "error"

module Hron
  # Token kinds (using symbols and Data classes)
  module TokenKind
    EVERY = :every
    ON = :on
    AT = :at
    FROM = :from
    TO = :to
    IN = :in
    OF = :of
    THE = :the
    LAST = :last
    EXCEPT = :except
    UNTIL = :until
    STARTING = :starting
    DURING = :during
    YEAR = :year
    NEAREST = :nearest
    NEXT = :next
    PREVIOUS = :previous
    DAY = :day
    WEEKDAY_KW = :weekday_kw
    WEEKEND_KW = :weekend_kw
    WEEKS = :weeks
    MONTH = :month
    COMMA = :comma
  end

  # Token types with values
  TDayName = Data.define(:name)
  TMonthName = Data.define(:name)
  TOrdinal = Data.define(:position)
  TIntervalUnit = Data.define(:unit)
  TNumber = Data.define(:value)
  TOrdinalNumber = Data.define(:value)
  TTime = Data.define(:hour, :minute)
  TIsoDate = Data.define(:date)
  TTimezone = Data.define(:tz)

  # Token with kind and span
  Token = Data.define(:kind, :span)

  # Keyword mapping
  KEYWORD_MAP = {
    "every" => TokenKind::EVERY,
    "on" => TokenKind::ON,
    "at" => TokenKind::AT,
    "from" => TokenKind::FROM,
    "to" => TokenKind::TO,
    "in" => TokenKind::IN,
    "of" => TokenKind::OF,
    "the" => TokenKind::THE,
    "last" => TokenKind::LAST,
    "except" => TokenKind::EXCEPT,
    "until" => TokenKind::UNTIL,
    "starting" => TokenKind::STARTING,
    "during" => TokenKind::DURING,
    "year" => TokenKind::YEAR,
    "years" => TokenKind::YEAR,
    "nearest" => TokenKind::NEAREST,
    "next" => TokenKind::NEXT,
    "previous" => TokenKind::PREVIOUS,
    "day" => TokenKind::DAY,
    "days" => TokenKind::DAY,
    "weekday" => TokenKind::WEEKDAY_KW,
    "weekdays" => TokenKind::WEEKDAY_KW,
    "weekend" => TokenKind::WEEKEND_KW,
    "weekends" => TokenKind::WEEKEND_KW,
    "weeks" => TokenKind::WEEKS,
    "week" => TokenKind::WEEKS,
    "month" => TokenKind::MONTH,
    "months" => TokenKind::MONTH,
    # Day names
    "monday" => TDayName.new(Weekday::MONDAY),
    "mon" => TDayName.new(Weekday::MONDAY),
    "tuesday" => TDayName.new(Weekday::TUESDAY),
    "tue" => TDayName.new(Weekday::TUESDAY),
    "wednesday" => TDayName.new(Weekday::WEDNESDAY),
    "wed" => TDayName.new(Weekday::WEDNESDAY),
    "thursday" => TDayName.new(Weekday::THURSDAY),
    "thu" => TDayName.new(Weekday::THURSDAY),
    "friday" => TDayName.new(Weekday::FRIDAY),
    "fri" => TDayName.new(Weekday::FRIDAY),
    "saturday" => TDayName.new(Weekday::SATURDAY),
    "sat" => TDayName.new(Weekday::SATURDAY),
    "sunday" => TDayName.new(Weekday::SUNDAY),
    "sun" => TDayName.new(Weekday::SUNDAY),
    # Month names
    "january" => TMonthName.new(MonthName::JAN),
    "jan" => TMonthName.new(MonthName::JAN),
    "february" => TMonthName.new(MonthName::FEB),
    "feb" => TMonthName.new(MonthName::FEB),
    "march" => TMonthName.new(MonthName::MAR),
    "mar" => TMonthName.new(MonthName::MAR),
    "april" => TMonthName.new(MonthName::APR),
    "apr" => TMonthName.new(MonthName::APR),
    "may" => TMonthName.new(MonthName::MAY),
    "june" => TMonthName.new(MonthName::JUN),
    "jun" => TMonthName.new(MonthName::JUN),
    "july" => TMonthName.new(MonthName::JUL),
    "jul" => TMonthName.new(MonthName::JUL),
    "august" => TMonthName.new(MonthName::AUG),
    "aug" => TMonthName.new(MonthName::AUG),
    "september" => TMonthName.new(MonthName::SEP),
    "sep" => TMonthName.new(MonthName::SEP),
    "october" => TMonthName.new(MonthName::OCT),
    "oct" => TMonthName.new(MonthName::OCT),
    "november" => TMonthName.new(MonthName::NOV),
    "nov" => TMonthName.new(MonthName::NOV),
    "december" => TMonthName.new(MonthName::DEC),
    "dec" => TMonthName.new(MonthName::DEC),
    # Ordinals
    "first" => TOrdinal.new(OrdinalPosition::FIRST),
    "second" => TOrdinal.new(OrdinalPosition::SECOND),
    "third" => TOrdinal.new(OrdinalPosition::THIRD),
    "fourth" => TOrdinal.new(OrdinalPosition::FOURTH),
    "fifth" => TOrdinal.new(OrdinalPosition::FIFTH),
    # Interval units
    "min" => TIntervalUnit.new(IntervalUnit::MIN),
    "mins" => TIntervalUnit.new(IntervalUnit::MIN),
    "minute" => TIntervalUnit.new(IntervalUnit::MIN),
    "minutes" => TIntervalUnit.new(IntervalUnit::MIN),
    "hour" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hours" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hr" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hrs" => TIntervalUnit.new(IntervalUnit::HOURS)
  }.freeze

  # Lexer class
  class Lexer
    def initialize(input)
      @input = input
      @pos = 0
      @after_in = false
    end

    def tokenize
      tokens = []
      loop do
        skip_whitespace
        break if @pos >= @input.length

        if @after_in
          @after_in = false
          tokens << lex_timezone
          next
        end

        start = @pos
        ch = @input[@pos]

        if ch == ","
          @pos += 1
          tokens << Token.new(TokenKind::COMMA, Span.new(start, @pos))
          next
        end

        if ch.match?(/\d/)
          tokens << lex_number_or_time_or_date
          next
        end

        if ch.match?(/[a-zA-Z]/)
          tokens << lex_word
          next
        end

        raise HronError.lex("unexpected character '#{ch}'", Span.new(start, start + 1), @input)
      end
      tokens
    end

    private

    def skip_whitespace
      @pos += 1 while @pos < @input.length && @input[@pos].match?(/\s/)
    end

    def lex_timezone
      skip_whitespace
      start = @pos
      @pos += 1 while @pos < @input.length && !@input[@pos].match?(/\s/)
      tz = @input[start...@pos]
      raise HronError.lex("expected timezone after 'in'", Span.new(start, start + 1), @input) if tz.empty?

      Token.new(TTimezone.new(tz), Span.new(start, @pos))
    end

    def lex_number_or_time_or_date
      start = @pos
      @pos += 1 while @pos < @input.length && @input[@pos].match?(/\d/)
      digits = @input[start...@pos]

      # Check for ISO date: YYYY-MM-DD
      if digits.length == 4 && @pos < @input.length && @input[@pos] == "-"
        remaining = @input[start..]
        if remaining.length >= 10 &&
            remaining[4] == "-" &&
            remaining[5..6].match?(/\d{2}/) &&
            remaining[7] == "-" &&
            remaining[8..9].match?(/\d{2}/)
          @pos = start + 10
          return Token.new(TIsoDate.new(@input[start...@pos]), Span.new(start, @pos))
        end
      end

      # Check for time: HH:MM
      if digits.length.between?(1, 2) && @pos < @input.length && @input[@pos] == ":"
        @pos += 1 # skip ':'
        min_start = @pos
        @pos += 1 while @pos < @input.length && @input[@pos].match?(/\d/)
        min_digits = @input[min_start...@pos]
        if min_digits.length == 2
          hour = digits.to_i
          minute = min_digits.to_i
          raise HronError.lex("invalid time", Span.new(start, @pos), @input) if hour > 23 || minute > 59

          return Token.new(TTime.new(hour, minute), Span.new(start, @pos))
        end
      end

      num = digits.to_i

      # Check for ordinal suffix: st, nd, rd, th
      if @pos + 1 < @input.length
        suffix = @input[@pos, 2].downcase
        if %w[st nd rd th].include?(suffix)
          @pos += 2
          return Token.new(TOrdinalNumber.new(num), Span.new(start, @pos))
        end
      end

      Token.new(TNumber.new(num), Span.new(start, @pos))
    end

    def lex_word
      start = @pos
      @pos += 1 while @pos < @input.length && @input[@pos].match?(/\w/)
      word = @input[start...@pos].downcase
      span = Span.new(start, @pos)

      kind = KEYWORD_MAP[word]
      raise HronError.lex("unknown keyword '#{word}'", span, @input) if kind.nil?

      @after_in = true if kind == TokenKind::IN

      Token.new(kind, span)
    end
  end

  def self.tokenize(input)
    Lexer.new(input).tokenize
  end
end
