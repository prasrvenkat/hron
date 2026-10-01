# frozen_string_literal: true

require_relative "ast"
require_relative "error"

module Hron
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

  TDayName = Data.define(:name)
  TMonthName = Data.define(:name)
  TOrdinal = Data.define(:position)
  TIntervalUnit = Data.define(:unit)
  TNumber = Data.define(:value)
  TOrdinalNumber = Data.define(:value)
  TTime = Data.define(:hour, :minute)
  TIsoDate = Data.define(:date)
  TTimezone = Data.define(:tz)

  Token = Data.define(:kind, :span)

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
    "first" => TOrdinal.new(OrdinalPosition::FIRST),
    "second" => TOrdinal.new(OrdinalPosition::SECOND),
    "third" => TOrdinal.new(OrdinalPosition::THIRD),
    "fourth" => TOrdinal.new(OrdinalPosition::FOURTH),
    "fifth" => TOrdinal.new(OrdinalPosition::FIFTH),
    "min" => TIntervalUnit.new(IntervalUnit::MIN),
    "mins" => TIntervalUnit.new(IntervalUnit::MIN),
    "minute" => TIntervalUnit.new(IntervalUnit::MIN),
    "minutes" => TIntervalUnit.new(IntervalUnit::MIN),
    "hour" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hours" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hr" => TIntervalUnit.new(IntervalUnit::HOURS),
    "hrs" => TIntervalUnit.new(IntervalUnit::HOURS)
  }.freeze

  class Lexer
    # Every number must fit a 32-bit signed integer, which is also the largest interval.
    MAX_NUMBER = 2_147_483_647
    ORDINAL_SUFFIXES = %w[st nd rd th].freeze
    ISO_DATE_TAIL_LENGTH = 6
    private_constant :ORDINAL_SUFFIXES, :ISO_DATE_TAIL_LENGTH

    def initialize(input)
      @input = input
      @chars = Utf8.convert(input).chars
      @pos = 0
    end

    def tokenize
      tokens = []
      loop do
        advance_while { |c| separator?(c) }
        break if @pos >= @chars.length

        start = @pos
        c = @chars[@pos]
        kind = if tokens.last&.kind == TokenKind::IN
          advance_while { |ch| !separator?(ch) }
          TTimezone.new(text(start))
        elsif c == ","
          @pos += 1
          TokenKind::COMMA
        elsif c.match?(/[A-Za-z]/)
          word(start)
        elsif digit?(c)
          digits(start)
        else
          raise unexpected_character(c, start)
        end
        tokens << Token.new(kind, Span.new(start, @pos))
      end
      tokens
    end

    private

    # Only these four separate tokens; `\s` and `strip` would also take \v, \f or NUL.
    def separator?(c)
      c == " " || c == "\t" || c == "\r" || c == "\n"
    end

    def digit?(c)
      c&.match?(/[0-9]/)
    end

    def advance_while
      @pos += 1 while @pos < @chars.length && yield(@chars[@pos])
    end

    def text(start, stop = @pos)
      @chars[start...stop].join
    end

    def error(message, start)
      HronError.lex(message, Span.new(start, @pos), @input)
    end

    def word(start)
      advance_while { |c| c.match?(/[A-Za-z0-9_]/) }
      written = text(start)
      KEYWORD_MAP[written.downcase(:ascii)] or raise error("unknown keyword '#{written}'", start)
    end

    def digits(start)
      advance_while { |c| digit?(c) }
      if @pos - start == 4 && iso_date_tail?
        @pos += ISO_DATE_TAIL_LENGTH
        return TIsoDate.new(text(start))
      end
      return time(start) if @chars[@pos] == ":"

      value = number_value(text(start)) or raise error("number must be at most #{MAX_NUMBER}", start)
      if ORDINAL_SUFFIXES.include?(@chars[@pos, 2].join.downcase(:ascii))
        @pos += 2
        return TOrdinalNumber.new(value)
      end
      TNumber.new(value)
    end

    def iso_date_tail?
      tail = @chars[@pos, ISO_DATE_TAIL_LENGTH]
      tail.length == ISO_DATE_TAIL_LENGTH && tail[0] == "-" && tail[3] == "-" && [1, 2, 4, 5].all? { |i| digit?(tail[i]) }
    end

    # Integer() would read a leading zero as octal and accept "_" or a sign, and stopping at the
    # limit keeps a run of thousands of digits from becoming a huge Integer.
    def number_value(digits)
      digits.each_char.reduce(0) do |n, d|
        n = (n * 10) + d.ord - "0".ord
        return nil if n > MAX_NUMBER

        n
      end
    end

    def time(start)
      colon = @pos
      @pos += 1
      advance_while { |c| digit?(c) }
      hour = text(start, colon)
      minute = text(colon + 1)
      written = text(start)
      unless hour.length.between?(1, 2) && minute.length == 2
        raise error("time must be H:MM or HH:MM, got #{written}", start)
      end
      raise error("time must be 00:00-23:59, got #{written}", start) if hour.to_i > 23 || minute.to_i > 59

      TTime.new(hour.to_i, minute.to_i)
    end

    def unexpected_character(c, start)
      # `'` is excluded because `'''` would not read as a quoted character.
      shown = (c.ord.between?(0x21, 0x7E) && c != "'") ? "'#{c}'" : format("U+%04X", c.ord)
      HronError.lex("unexpected character #{shown}", Span.new(start, start + 1), @input)
    end
  end

  def self.tokenize(input)
    Lexer.new(input).tokenize
  end
end
