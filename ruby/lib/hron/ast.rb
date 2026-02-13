# frozen_string_literal: true

module Hron
  # Weekday enumeration (ISO 8601: Monday=1, Sunday=7)
  module Weekday
    MONDAY = :monday
    TUESDAY = :tuesday
    WEDNESDAY = :wednesday
    THURSDAY = :thursday
    FRIDAY = :friday
    SATURDAY = :saturday
    SUNDAY = :sunday

    ALL = [MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY, SATURDAY, SUNDAY].freeze
    WEEKDAYS = [MONDAY, TUESDAY, WEDNESDAY, THURSDAY, FRIDAY].freeze
    WEEKEND = [SATURDAY, SUNDAY].freeze

    NUMBERS = {
      MONDAY => 1, TUESDAY => 2, WEDNESDAY => 3, THURSDAY => 4,
      FRIDAY => 5, SATURDAY => 6, SUNDAY => 7
    }.freeze

    CRON_DOW = {
      SUNDAY => 0, MONDAY => 1, TUESDAY => 2, WEDNESDAY => 3,
      THURSDAY => 4, FRIDAY => 5, SATURDAY => 6
    }.freeze

    NUMBER_TO_WEEKDAY = NUMBERS.invert.freeze

    PARSE_MAP = {
      "monday" => MONDAY, "mon" => MONDAY,
      "tuesday" => TUESDAY, "tue" => TUESDAY,
      "wednesday" => WEDNESDAY, "wed" => WEDNESDAY,
      "thursday" => THURSDAY, "thu" => THURSDAY,
      "friday" => FRIDAY, "fri" => FRIDAY,
      "saturday" => SATURDAY, "sat" => SATURDAY,
      "sunday" => SUNDAY, "sun" => SUNDAY
    }.freeze

    def self.number(day)
      NUMBERS[day]
    end

    def self.cron_dow(day)
      CRON_DOW[day]
    end

    def self.from_number(n)
      NUMBER_TO_WEEKDAY[n]
    end

    def self.try_parse(s)
      PARSE_MAP[s.downcase]
    end

    def self.to_s(day)
      day.to_s
    end
  end

  # Month name enumeration
  module MonthName
    JAN = :jan
    FEB = :feb
    MAR = :mar
    APR = :apr
    MAY = :may
    JUN = :jun
    JUL = :jul
    AUG = :aug
    SEP = :sep
    OCT = :oct
    NOV = :nov
    DEC = :dec

    ALL = [JAN, FEB, MAR, APR, MAY, JUN, JUL, AUG, SEP, OCT, NOV, DEC].freeze

    NUMBERS = {
      JAN => 1, FEB => 2, MAR => 3, APR => 4, MAY => 5, JUN => 6,
      JUL => 7, AUG => 8, SEP => 9, OCT => 10, NOV => 11, DEC => 12
    }.freeze

    NUMBER_TO_MONTH = NUMBERS.invert.freeze

    PARSE_MAP = {
      "january" => JAN, "jan" => JAN,
      "february" => FEB, "feb" => FEB,
      "march" => MAR, "mar" => MAR,
      "april" => APR, "apr" => APR,
      "may" => MAY,
      "june" => JUN, "jun" => JUN,
      "july" => JUL, "jul" => JUL,
      "august" => AUG, "aug" => AUG,
      "september" => SEP, "sep" => SEP,
      "october" => OCT, "oct" => OCT,
      "november" => NOV, "nov" => NOV,
      "december" => DEC, "dec" => DEC
    }.freeze

    def self.number(month)
      NUMBERS[month]
    end

    def self.from_number(n)
      NUMBER_TO_MONTH[n]
    end

    def self.try_parse(s)
      PARSE_MAP[s.downcase]
    end

    def self.to_s(month)
      month.to_s
    end
  end

  # Interval unit (minutes or hours)
  module IntervalUnit
    MIN = :min
    HOURS = :hours

    def self.to_s(unit)
      unit.to_s
    end
  end

  # Ordinal position (first, second, etc.)
  module OrdinalPosition
    FIRST = :first
    SECOND = :second
    THIRD = :third
    FOURTH = :fourth
    FIFTH = :fifth
    LAST = :last

    TO_N = {
      FIRST => 1, SECOND => 2, THIRD => 3, FOURTH => 4, FIFTH => 5
    }.freeze

    def self.to_n(ord)
      TO_N[ord]
    end

    def self.to_s(ord)
      ord.to_s
    end
  end

  # Time of day (hour and minute)
  TimeOfDay = Data.define(:hour, :minute) do
    def to_s
      format("%02d:%02d", hour, minute)
    end
  end

  # --- Day filter variants ---

  DayFilterEvery = Data.define
  DayFilterWeekday = Data.define
  DayFilterWeekend = Data.define
  DayFilterDays = Data.define(:days) # days: Array<Weekday>

  # --- Day of month spec ---

  SingleDay = Data.define(:day)
  DayRange = Data.define(:start, :end_day) # end_day to avoid Ruby keyword

  # --- Month target variants ---

  DaysTarget = Data.define(:specs) # specs: Array<DayOfMonthSpec>
  LastDayTarget = Data.define
  LastWeekdayTarget = Data.define

  # --- Year target variants ---

  YearDateTarget = Data.define(:month, :day)
  YearOrdinalWeekdayTarget = Data.define(:ordinal, :weekday, :month)
  YearDayOfMonthTarget = Data.define(:day, :month)
  YearLastWeekdayTarget = Data.define(:month)

  # --- Date spec variants ---

  NamedDate = Data.define(:month, :day)
  IsoDate = Data.define(:date) # date: String (YYYY-MM-DD)

  # --- Exception spec variants ---

  NamedException = Data.define(:month, :day)
  IsoException = Data.define(:date)

  # --- Until spec variants ---

  IsoUntil = Data.define(:date)
  NamedUntil = Data.define(:month, :day)

  # --- Schedule expression variants ---

  IntervalRepeat = Data.define(:interval, :unit, :from_time, :to_time, :day_filter)
  DayRepeat = Data.define(:interval, :days, :times)
  WeekRepeat = Data.define(:interval, :days, :times)
  MonthRepeat = Data.define(:interval, :target, :times)
  OrdinalRepeat = Data.define(:interval, :ordinal, :day, :times)
  SingleDateExpr = Data.define(:date, :times)
  YearRepeat = Data.define(:interval, :target, :times)

  # --- Schedule data (top-level) ---

  ScheduleData = Data.define(:expr, :timezone, :except, :until, :anchor, :during) do
    def initialize(expr:, timezone: nil, except: [], until: nil, anchor: nil, during: [])
      super
    end
  end

  # --- Helper functions ---

  def self.expand_day_spec(spec)
    case spec
    when SingleDay
      [spec.day]
    when DayRange
      (spec.start..spec.end_day).to_a
    else
      []
    end
  end

  def self.expand_month_target(target)
    case target
    when DaysTarget
      target.specs.flat_map { |spec| expand_day_spec(spec) }
    else
      []
    end
  end
end
