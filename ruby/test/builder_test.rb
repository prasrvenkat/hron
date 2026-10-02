# frozen_string_literal: true

require_relative "test_helper"

class BuilderTest < Minitest::Test
  NINE = Hron::TimeOfDay.new(9, 0)
  NOW = Time.utc(2026, 2, 6, 12, 0, 0)

  def every_day(times = [NINE])
    Hron::DayRepeat.new(1, Hron::DayFilterEvery.new, times)
  end

  def build(expr = every_day, **clauses)
    Hron::Schedule.new(Hron::ScheduleData.new(expr: expr, **clauses))
  end

  def eval_message
    error = assert_raises(Hron::HronError) { yield }
    assert_equal :eval, error.kind
    error.message
  end

  def test_later_changes_to_the_callers_parts_are_not_seen
    times = [Hron::TimeOfDay.new(9, 0)]
    days = [Hron::Weekday::MONDAY]
    except = [Hron::IsoException.new(+"2026-12-25")]
    during = [Hron::MonthName::JAN]
    anchor = +"2026-01-05"
    timezone = +"Europe/London"
    schedule = build(Hron::WeekRepeat.new(1, days, times), except: except, anchor: anchor, during: during, timezone: timezone)
    before = schedule.to_s

    times << Hron::TimeOfDay.new(17, 0)
    days << Hron::Weekday::FRIDAY
    except.first.date.replace("2026-12-26")
    except << Hron::NamedException.new(Hron::MonthName::JAN, 1)
    during << Hron::MonthName::FEB
    anchor.replace("2026-01-06")
    timezone.replace("Asia/Tokyo")

    assert_equal "every week on monday at 09:00 except 2026-12-25 starting 2026-01-05 during jan in Europe/London", before
    assert_equal before, schedule.to_s
    refute times.frozen?, "the caller's own list stays the caller's"
    refute anchor.frozen?
  end

  def test_what_the_getters_return_cannot_change_the_schedule
    schedule = Hron::Schedule.parse("every monday at 09:00 except 2026-12-25 during jan in UTC")
    before = schedule.to_s
    assert_raises(FrozenError) { schedule.expression.days.days << Hron::Weekday::FRIDAY }
    assert_raises(FrozenError) { schedule.expression.times << NINE }
    assert_raises(FrozenError) { schedule.data.except.first.date << "x" }
    assert_raises(FrozenError) { schedule.data.during.clear }
    assert_raises(FrozenError) { schedule.timezone << "x" }
    assert Ractor.shareable?(schedule.data)
    assert_equal before, schedule.to_s
  end

  def test_a_built_schedule_is_deeply_frozen_too
    assert Ractor.shareable?(build(Hron::WeekRepeat.new(1, [Hron::Weekday::MONDAY], [NINE]), except: [Hron::IsoException.new(+"2026-12-25")]).data)
  end

  def test_data_with_changes_builds_a_changed_copy
    schedule = Hron::Schedule.parse("every day at 09:00")
    changed = Hron::Schedule.new(schedule.data.with(timezone: "asia/tokyo"))
    assert_equal "every day at 09:00 in Asia/Tokyo", changed.to_s
    assert_equal "every day at 09:00", schedule.to_s
    assert_equal "Asia/Tokyo", changed.timezone
  end

  def test_equal_parts_are_the_same_schedule
    built = build(timezone: "utc")
    parsed = Hron::Schedule.parse("every day at 09:00 in UTC")
    assert_equal parsed, built
    assert parsed.eql?(built)
    assert_equal parsed.hash, built.hash
    refute_equal Hron::Schedule.parse("every day at 09:01 in UTC"), built
  end

  def test_an_empty_except_or_during_list_is_no_clause
    assert_equal Hron::Schedule.parse("every day at 09:00"), build(except: [], during: [])
  end

  def test_a_built_schedule_evaluates_like_the_parsed_one
    built = build(Hron::YearRepeat.new(1, Hron::YearOrdinalWeekdayTarget.new(:last, :friday, :nov), [NINE]), timezone: "america/new_york")
    parsed = Hron::Schedule.parse("every year on the last friday of nov at 09:00 in America/New_York")
    assert_equal parsed.next_n_from(NOW, 3), built.next_n_from(NOW, 3)
    assert_equal "0 9 * 11 5L", built.to_cron
  end

  def test_names_are_symbols_and_any_other_type_is_a_type_error
    assert_raises(TypeError) { build(Hron::WeekRepeat.new(1, ["monday"], [NINE])) }
    assert_raises(TypeError) { build(during: ["jan"]) }
    assert_raises(TypeError) { build(Hron::IntervalRepeat.new(1, "min", NINE, NINE, nil)) }
    assert_raises(TypeError) { build(Hron::MonthRepeat.new(1, Hron::OrdinalWeekdayTarget.new("first", :monday), [NINE])) }
    assert_raises(TypeError) { build(Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(15, "next"), [NINE])) }
  end

  def test_a_value_of_the_wrong_type_is_a_type_error
    [
      -> { Hron::Schedule.new("every day at 09:00") },
      -> { Hron::Schedule.new(nil) },
      -> { build(Hron::DayRepeat.new("1", Hron::DayFilterEvery.new, [NINE])) },
      -> { build(Hron::DayRepeat.new(1.0, Hron::DayFilterEvery.new, [NINE])) },
      -> { build(every_day(nil)) },
      -> { build(every_day(["09:00"])) },
      -> { build(every_day([Hron::TimeOfDay.new(9.5, 0)])) },
      -> { build(every_day([Hron::TimeOfDay.new(9, nil)])) },
      -> { build(Hron::DayRepeat.new(1, Hron::DayFilterDays.new(nil), [NINE])) },
      -> { build(Hron::MonthRepeat.new(1, Hron::DaysTarget.new([Hron::SingleDay.new("1")]), [NINE])) },
      -> { build(Hron::SingleDateExpr.new(Hron::IsoDate.new(Date.new(2026, 3, 1)), [NINE])) },
      -> { build(except: nil) },
      -> { build(during: nil) },
      -> { build(anchor: Date.new(2026, 1, 1)) },
      -> { build(timezone: :utc) },
      -> { build(timezone: false) }
    ].each_with_index do |call, i|
      error = assert_raises(TypeError, "call #{i}") { call.call }
      refute_kind_of Hron::HronError, error
    end
  end

  def test_a_symbol_that_is_not_a_name_of_its_kind_is_unknown
    assert_equal "unknown weekday :funday", eval_message { build(Hron::WeekRepeat.new(1, [:funday], [NINE])) }
    assert_equal "unknown month :january", eval_message { build(during: [:january]) }
    assert_equal "unknown interval unit :seconds", eval_message { build(Hron::IntervalRepeat.new(1, :seconds, NINE, NINE, nil)) }
    assert_equal "unknown ordinal :sixth", eval_message { build(Hron::MonthRepeat.new(1, Hron::OrdinalWeekdayTarget.new(:sixth, :monday), [NINE])) }
    assert_equal "unknown direction :nearest", eval_message { build(Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(15, :nearest), [NINE])) }
  end

  def test_a_value_outside_a_union_of_the_ast_is_unknown
    filter_days = Hron::DayFilterDays.new([:monday])
    assert_equal "unknown expression nil", eval_message { build(nil) }
    assert_equal 'unknown expression "every day at 09:00"', eval_message { build("every day at 09:00") }
    assert_equal 'unknown day filter "weekday"', eval_message { build(Hron::DayRepeat.new(1, "weekday", [NINE])) }
    assert_equal "unknown day filter nil", eval_message { build(Hron::DayRepeat.new(1, nil, [NINE])) }
    assert_equal "unknown day spec 5", eval_message { build(Hron::MonthRepeat.new(1, Hron::DaysTarget.new([5]), [NINE])) }
    assert_equal "unknown month target #{filter_days.inspect}", eval_message { build(Hron::MonthRepeat.new(1, filter_days, [NINE])) }
    assert_equal "unknown year target :last_day", eval_message { build(Hron::YearRepeat.new(1, :last_day, [NINE])) }
    assert_equal 'unknown date "2026-03-01"', eval_message { build(Hron::SingleDateExpr.new("2026-03-01", [NINE])) }
    named_date = Hron::NamedDate.new(:dec, 25)
    assert_equal "unknown exception #{named_date.inspect}", eval_message { build(except: [named_date]) }
    assert_equal 'unknown until "2026-12-31"', eval_message { build(until: "2026-12-31") }
  end

  def test_unknown_names_are_checked_first_in_their_part_and_parts_in_to_s_order
    window = ->(unit, from) { Hron::IntervalRepeat.new(0, unit, from, NINE, nil) }
    assert_equal "interval must be 1-2147483647, got 0", eval_message { build(window.call(:seconds, Hron::TimeOfDay.new(24, 0))) }
    window = ->(unit, from) { Hron::IntervalRepeat.new(1, unit, from, NINE, nil) }
    assert_equal "unknown interval unit :seconds", eval_message { build(window.call(:seconds, Hron::TimeOfDay.new(24, 0))) }
    assert_equal "unknown month :dec_", eval_message { build(Hron::YearRepeat.new(1, Hron::YearDateTarget.new(:dec_, 40), [NINE])) }
    assert_equal "unknown month :dec_", eval_message { build(Hron::YearRepeat.new(1, Hron::YearDayOfMonthTarget.new(40, :dec_), [NINE])) }
    assert_equal "days must be every day when the interval is above 1", eval_message { build(Hron::DayRepeat.new(2, "weekday", [NINE])) }
    assert_equal "unknown direction :up", eval_message { build(Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(40, :up), [NINE])) }
    assert_equal "unknown ordinal :zeroth", eval_message { build(Hron::YearRepeat.new(1, Hron::YearOrdinalWeekdayTarget.new(:zeroth, :funday, :dec_), [NINE])) }
  end

  def test_integers_beyond_the_spec_types_are_written_as_given
    assert_equal "interval must be 1-2147483647, got -1", eval_message { build(Hron::DayRepeat.new(-1, Hron::DayFilterEvery.new, [NINE])) }
    assert_equal "interval must be 1-2147483647, got #{2**70}", eval_message { build(Hron::DayRepeat.new(2**70, Hron::DayFilterEvery.new, [NINE])) }
    assert_equal "time must be 00:00-23:59, got -1:00", eval_message { build(every_day([Hron::TimeOfDay.new(-1, 0)])) }
    assert_equal "time must be 00:00-23:59, got 09:-5", eval_message { build(every_day([Hron::TimeOfDay.new(9, -5)])) }
    assert_equal "day must be 1-31, got -1th", eval_message { build(Hron::MonthRepeat.new(1, Hron::DaysTarget.new([Hron::SingleDay.new(-1)]), [NINE])) }
    assert_equal "day must be 1-31, got 256th", eval_message { build(Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(256, nil), [NINE])) }
  end

  def test_a_day_below_1_is_written_with_th
    [-1, -7, -8, -9, -11, -21, 0].each do |day|
      expected = "day must be 1-31, got #{day}th"
      assert_equal expected, eval_message { build(Hron::MonthRepeat.new(1, Hron::DaysTarget.new([Hron::SingleDay.new(day)]), [NINE])) }
      assert_equal expected, eval_message { build(Hron::MonthRepeat.new(1, Hron::DaysTarget.new([Hron::DayRange.new(5, day)]), [NINE])) }
      assert_equal expected, eval_message { build(Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(day, nil), [NINE])) }
      assert_equal expected, eval_message { build(Hron::YearRepeat.new(1, Hron::YearDayOfMonthTarget.new(day, :mar), [NINE])) }
    end
  end

  def test_a_part_of_a_subclass_is_copied_as_its_own_class
    moment = Class.new(Hron::TimeOfDay)
    days = Class.new(Hron::DayRepeat)
    target = Class.new(Hron::NearestWeekdayTarget)
    parts = Class.new(Hron::ScheduleData)
    list = Class.new(Array)
    every_day = build(days.new(1, Hron::DayFilterEvery.new, list[moment.new(9, 0)]))
    assert_equal Hron::Schedule.parse("every day at 09:00"), every_day
    assert_instance_of Hron::DayRepeat, every_day.expression
    assert_instance_of Array, every_day.expression.times
    assert_instance_of Hron::TimeOfDay, every_day.expression.times.first
    monthly = Hron::Schedule.new(parts.new(expr: Hron::MonthRepeat.new(1, target.new(15, nil), [NINE]), anchor: Class.new(String).new("2026-01-01")))
    assert_equal Hron::Schedule.parse(monthly.to_s), monthly
    assert_instance_of Hron::ScheduleData, monthly.data
    assert_instance_of Hron::NearestWeekdayTarget, monthly.expression.target
    assert_instance_of String, monthly.data.anchor
  end

  def test_dates_and_timezones_in_other_encodings
    utf16 = "2026-03-01".encode(Encoding::UTF_16LE)
    assert_equal "date must be a calendar date from 0001-01-01 to 9999-12-31, got 2026-03-01",
      eval_message { build(Hron::SingleDateExpr.new(Hron::IsoDate.new(utf16), [NINE])) }
    # Ten UTF-16 bytes that spell an ISO date are five CJK characters.
    cjk = "㈰㈶ⴰ㈭〱".encode(Encoding::UTF_16BE)
    assert_equal "2026-02-01", cjk.b
    assert_match(/\Adate must be a calendar date/, eval_message { build(anchor: cjk) })
    assert_equal "on 2026-03-01 at 09:00", build(Hron::SingleDateExpr.new(Hron::IsoDate.new("2026-03-01".b), [NINE])).to_s
    assert_equal "timezone must be UTC or an Area/Location name such as America/New_York, got UTC",
      eval_message { build(timezone: "UTC".encode(Encoding::UTF_16LE)) }
    invalid = "Europe/\xFF".dup.force_encoding(Encoding::UTF_8)
    assert_equal "timezone must be UTC or an Area/Location name such as America/New_York, got Europe/�",
      eval_message { build(timezone: invalid) }
  end

  def test_ordinal_position_numbers
    expected = {first: 1, second: 2, third: 3, fourth: 4, fifth: 5, last: -1}
    assert_equal expected, Hron::OrdinalPosition::ALL.to_h { |ordinal| [ordinal, Hron::OrdinalPosition.to_n(ordinal)] }
  end

  def test_internals_that_take_unchecked_parts_are_private
    assert_empty Hron.constants & %i[Parser Evaluator Display Cron Parts]
    refute_respond_to Hron, :parse
  end

  # Mostly values that keep the rules, with values just past each limit mixed in, so that
  # many parts build and many fail (spec/README.md, "Schedules built in code").
  class RandomParts
    MONTHS = %i[jan feb apr].freeze

    def initialize(rng)
      @rng = rng
    end

    def pick(*weighted)
      total = weighted.sum(&:first)
      roll = @rng.rand(total)
      weighted.each do |weight, value|
        return value.respond_to?(:call) ? value.call : value if roll < weight
        roll -= weight
      end
    end

    def time = Hron::TimeOfDay.new(pick([19, -> { @rng.rand(24) }], [1, 24]), pick([19, -> { [0, 30, 59].sample(random: @rng) }], [1, 60]))
    def times = pick([19, -> { Array.new(1 + @rng.rand(2)) { time } }], [1, []])
    def interval = pick([10, 1], [6, 2], [2, 2_147_483_647], [1, 0], [1, 2_147_483_648])
    def day = pick([16, -> { 1 + @rng.rand(28) }], [3, -> { 29 + @rng.rand(3) }], [1, -> { [0, 32].sample(random: @rng) }])
    def weekday = Hron::Weekday::ALL.sample(random: @rng)
    def weekdays = pick([19, -> { Array.new(1 + @rng.rand(2)) { weekday } }], [1, []])
    def month = MONTHS.sample(random: @rng)
    def iso = pick([8, "2026-02-28"], [8, "2028-02-29"], [1, "2026-02-29"], [1, "0000-01-01"], [1, "20260206"])

    def day_filter
      pick([1, -> { Hron::DayFilterEvery.new }], [1, -> { Hron::DayFilterWeekday.new }], [1, -> { Hron::DayFilterWeekend.new }], [1, -> { Hron::DayFilterDays.new(weekdays) }])
    end

    def day_spec
      a = day
      b = day
      pick([8, -> { Hron::SingleDay.new(a) }], [8, -> { Hron::DayRange.new(*[a, b].minmax) }], [1, -> { Hron::DayRange.new(a, b) }])
    end

    def month_target
      pick(
        [1, -> { Hron::DaysTarget.new(pick([19, -> { Array.new(1 + @rng.rand(2)) { day_spec } }], [1, []])) }],
        [1, -> { Hron::LastDayTarget.new }],
        [1, -> { Hron::LastWeekdayTarget.new }],
        [1, -> { Hron::NearestWeekdayTarget.new(day, pick([1, nil], [1, :next])) }],
        [1, -> { Hron::OrdinalWeekdayTarget.new(:last, weekday) }]
      )
    end

    def year_target
      pick(
        [1, -> { Hron::YearDateTarget.new(month, day) }],
        [1, -> { Hron::YearDayOfMonthTarget.new(day, month) }],
        [1, -> { Hron::YearOrdinalWeekdayTarget.new(:fifth, weekday, month) }],
        [1, -> { Hron::YearLastWeekdayTarget.new(month) }]
      )
    end

    def expression
      pick(
        [1, -> { Hron::IntervalRepeat.new(interval, pick([1, :min], [1, :hours]), time, time, pick([1, nil], [1, -> { day_filter }])) }],
        [1, -> { Hron::DayRepeat.new(interval, day_filter, times) }],
        [1, -> { Hron::WeekRepeat.new(interval, weekdays, times) }],
        [1, -> { Hron::MonthRepeat.new(interval, month_target, times) }],
        [1, -> { Hron::SingleDateExpr.new(pick([1, -> { Hron::NamedDate.new(month, day) }], [1, -> { Hron::IsoDate.new(iso) }]), times) }],
        [1, -> { Hron::YearRepeat.new(interval, year_target, times) }]
      )
    end

    def data
      Hron::ScheduleData.new(
        expr: expression,
        timezone: pick([9, nil], [9, "utc"], [9, "america/new_york"], [1, "EST"]),
        except: Array.new(@rng.rand(2)) { pick([1, -> { Hron::NamedException.new(month, day) }], [1, -> { Hron::IsoException.new(iso) }]) },
        until: pick([1, nil], [1, -> { Hron::NamedUntil.new(month, day) }], [1, -> { Hron::IsoUntil.new(iso) }]),
        anchor: pick([1, nil], [19, "2026-02-06"], [1, "0000-01-01"]),
        during: Array.new(@rng.rand(2)) { month }
      )
    end
  end

  def test_built_schedules_keep_the_promises_of_parsed_ones
    parts = RandomParts.new(Random.new(0x5eed))
    built = 0
    1000.times do
      data = parts.data
      schedule = begin
        Hron::Schedule.new(data)
      rescue Hron::HronError => e
        assert_equal :eval, e.kind
        next
      end
      built += 1
      text = schedule.to_s
      assert_equal schedule, Hron::Schedule.parse(text), text
      begin
        schedule.to_cron
      rescue Hron::HronError => e
        assert_equal :cron, e.kind, text
      end
      after = schedule.next_from(NOW)
      assert schedule.matches(after), "#{text} at #{after}" if after
      schedule.previous_from(NOW)
    end
    assert_operator built, :>, 200, "too few parts built to test anything"
  end
end
