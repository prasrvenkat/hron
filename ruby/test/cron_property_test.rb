# frozen_string_literal: true

require_relative "test_helper"

# A cron matcher written from the cron rules alone, sharing no code with the gem.
# It expects valid syntax.
class NaiveCron
  MONTH_NAMES = %w[_ jan feb mar apr may jun jul aug sep oct nov dec].freeze
  DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze
  SHORTCUTS = {
    "@yearly" => "0 0 1 1 *", "@annually" => "0 0 1 1 *", "@monthly" => "0 0 1 * *",
    "@weekly" => "0 0 * * 0", "@daily" => "0 0 * * *", "@midnight" => "0 0 * * *",
    "@hourly" => "0 * * * *"
  }.freeze

  attr_reader :dom, :dow

  def initialize(cron)
    cron = cron.strip.downcase
    f = SHORTCUTS.fetch(cron, cron).split
    raise "naive matcher given #{cron.inspect}" unless f.length == 5

    @minutes = naive_set(f[0], 0, 59, 59)
    @hours = naive_set(f[1], 0, 23, 23)
    @months = naive_set(f[3], 1, 12, 12, MONTH_NAMES)
    @dom = case f[2]
    when "*", "?" then [:any]
    when "l" then [:last]
    when "lw" then [:last_weekday]
    when /w\z/ then [:nearest, naive_number(f[2][0...-1])]
    else [:days, naive_set(f[2], 1, 31, 31)]
    end
    @dow = case f[4]
    when "*", "?" then [:any]
    when /#/
      day, nth = f[4].split("#", 2)
      [:nth, naive_number(day, DAY_NAMES) % 7, naive_number(nth)]
    when /l\z/ then [:last, naive_number(f[4][0...-1], DAY_NAMES) % 7]
    else
      days = naive_set(f[4], 0, 7, 6, DAY_NAMES)
      days[0] ||= days[7]
      [:days, days.first(7)]
    end
  end

  def times
    (0..23).flat_map { |hour| (0..59).map { |minute| [hour, minute] } }
      .select { |hour, minute| @hours[hour] && @minutes[minute] }
  end

  def fires_on(date)
    day = date.day
    last = Date.new(date.year, date.month, -1).day
    weekdays = (1..last).reject { |n| Date.new(date.year, date.month, n).then { |d| d.saturday? || d.sunday? } }
    dom = case @dom
    in [:any] then nil
    in [:days, set] then set[day]
    in [:last] then day == last
    in [:last_weekday] then day == weekdays.last
    in [:nearest, n] then n <= last && day == weekdays.min_by { |w| (w - n).abs }
    end
    dow = case @dow
    in [:any] then nil
    in [:days, set] then set[date.wday]
    in [:nth, d, n] then date.wday == d && (day - 1) / 7 + 1 == n
    in [:last, d] then date.wday == d && day + 7 > last
    end
    restrictions = [dom, dow].compact
    @months[date.month] && (restrictions.empty? || restrictions.any?)
  end

  def both_days_restricted?
    @dom != [:any] && @dow != [:any]
  end

  def days_carry_an_interval?
    case [@dom, @dow]
    in [[:any], [:any] | [:days, _]] then true
    in [[:days, set], [:any]] then set[1..].all?
    else false
    end
  end

  private

  def naive_number(text, names = [])
    names.index(text) || Integer(text, 10)
  end

  def naive_set(field, min, max, star_max, names = [])
    set = Array.new(max + 1, false)
    field.split(",").each do |item|
      range, step = item.split("/", 2)
      step &&= naive_number(step)
      low, high = if range == "*"
        [min, star_max]
      elsif range.include?("-")
        range.split("-", 2).map { |value| naive_number(value, names) }
      else
        a = naive_number(range, names)
        [a, step ? [a, star_max].max : a]
      end
      value = low
      while value <= high
        set[value] = true
        value += step || 1
      end
    end
    set
  end
end

class CronPropertyTest < Minitest::Test
  # Two years around 2044-02-29, a leap day in a February with five Mondays.
  WINDOW_START = Date.new(2043, 6, 1)
  WINDOW_END = Date.new(2045, 6, 1)
  # Comparing every occurrence costs about 15 microseconds each.
  FULL_COMPARE_LIMIT = 20_000

  BOTH_DAYS = "not expressible in hron: cron fires on either the day of month or the day of week"
  INTERVAL_DAYS = "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days"

  def cron_message
    error = assert_raises(Hron::HronError) { yield }
    assert_equal :cron, error.kind
    error.message
  end

  def from_cron(cron)
    Hron::Schedule.from_cron(cron).to_s
  end

  def built(expr, during: [])
    Hron::Schedule.new(Hron::ScheduleData.new(expr: expr, during: during))
  end

  def window_days
    (WINDOW_START...WINDOW_END).to_a
  end

  def utc(date, hour, minute)
    Time.utc(date.year, date.month, date.day, hour, minute)
  end

  def wall(time)
    time = time.getutc
    [Date.new(time.year, time.month, time.day), [time.hour, time.min]]
  end

  def assert_fires_as(schedule, cron, label)
    times = cron.times
    days = window_days.select { |d| cron.fires_on(d) }
    if days.length * times.length <= FULL_COMPARE_LIMIT
      assert_each_occurrence(schedule, days, times, WINDOW_END, label)
      return
    end
    assert_each_occurrence(schedule, days[0, 2], times, days[1] + 1, label)
    # Too many to compare one by one. In UTC an hron schedule fires at the same
    # times on every day it fires, so the two days compared in full stand for the
    # times of the rest; on each day the first and the last time, searched from
    # the day before, show that it fires that day and on no day between.
    cursor = utc(WINDOW_START, 0, 0) - 1
    days.each do |d|
      first = schedule.next_from(cursor)
      assert_equal [d, times.first], first && wall(first), "#{label}: first time on #{d}"
      end_of_day = utc(d + 1, 0, 0)
      last = schedule.previous_from(end_of_day)
      assert_equal [d, times.last], last && wall(last), "#{label}: last time on #{d}"
      cursor = end_of_day - 1
    end
    after = schedule.next_from(cursor)
    assert after.nil? || wall(after)[0] >= WINDOW_END, "#{label}: fires on #{after}, after the last day the cron fires"
  end

  def assert_each_occurrence(schedule, days, times, end_date, label)
    expected = days.flat_map { |d| times.map { |t| [d, t] } }
    actual = schedule.between(utc(WINDOW_START, 0, 0) - 1, utc(end_date, 0, 0) - 1)
      .first(expected.length + 1).map { |t| wall(t) }
    index = (0..expected.length).find { |i| expected[i] != actual[i] }
    flunk "#{label}: expected #{expected[index].inspect}, got #{actual[index].inspect}" if index
  end

  def equal_gaps?(times)
    minutes = times.map { |hour, minute| hour * 60 + minute }
    minutes.length >= 3 && minutes.each_cons(2).all? { |a, b| b - a == minutes[1] - minutes[0] }
  end

  def too_many_times_message(times)
    return INTERVAL_DAYS if equal_gaps?(times)

    "not expressible in hron: #{times.length} times a day are too many to list"
  end

  # xorshift64*, so the generated cases are the same on every run.
  class Rng
    MASK = (1 << 64) - 1

    def initialize(seed)
      @state = seed
    end

    def pick(items)
      items[pick_index(items.length)]
    end

    def pick_index(length)
      @state ^= @state >> 12
      @state ^= (@state << 25) & MASK
      @state ^= @state >> 27
      (((@state * 0x2545_f491_4f6c_dd1d) & MASK) >> 32) % length
    end
  end

  MINUTE_FIELDS = %w[
    0 30 */15 0-30/10 5,35 * 59 */7 00 10-50/20 45/5 0/20 1-3 */99999999999999999999
    0,15,30,45 5-10/5 0-59/30 */20
  ].freeze
  HOUR_FIELDS = %w[
    9 * */2 9-17 9-17/2 0,12 23 0-20/4 */5 22,0,2 1-23 7/30 009 0-11 */1 12-12/250 0-16/4 1-21/4
  ].freeze
  DOM_FIELDS = %w[
    * 1 15 31 L LW 15W 1-5 1-31/10 ? 29 30 lw 1W 31W */2 1-31 5-20/3 15,1 02 l 28-31 30W 29w
    1-30 2-31
  ].freeze
  MONTH_FIELDS = %w[* 1 JAN 1-3 */3 2 dec 4 feb 1,7 jun-aug 12,1 */12 2/5 12-12/250 Sep 2 2].freeze
  DOW_FIELDS = %w[
    * 1-5 MON 0 7 5L 1#2 SUN#1 ? 1-5/2 sat,sun 0-7 7/2 5-7 fri#5 1#5 0l mon-fri/2 6,7 7,1 0-6
    5/1 */3 tue-thu 1,1,3 1-4 mon-thu 1-6 0-5 0,6,1 sun,sat
  ].freeze
  CRONS_PER_SHARD = 150

  # Two crons in three keep one day field `*`, so most convert; the third draws
  # both, so some are rejected for restricting both.
  def generated_crons(shard)
    rng = Rng.new(0x9e37_79b9_7f4a_7c15 ^ shard)
    Array.new(CRONS_PER_SHARD) do |i|
      dom, dow = case i % 3
      when 0 then [DOM_FIELDS, ["*"]]
      when 1 then [["*"], DOW_FIELDS]
      else [DOM_FIELDS, DOW_FIELDS]
      end
      [MINUTE_FIELDS, HOUR_FIELDS, dom, MONTH_FIELDS, dow].map { |field| rng.pick(field) }.join(" ")
    end
  end

  def check_from_cron(shard)
    accepted = 0
    generated_crons(shard).each do |cron|
      naive = NaiveCron.new(cron)
      times = naive.times
      if naive.both_days_restricted?
        assert_equal BOTH_DAYS, cron_message { Hron::Schedule.from_cron(cron) }, cron
        next
      end
      if times.length > 24 && !(naive.days_carry_an_interval? && equal_gaps?(times))
        assert_equal too_many_times_message(times), cron_message { Hron::Schedule.from_cron(cron) }, cron
        next
      end
      schedule = Hron::Schedule.from_cron(cron)
      assert_fires_as(schedule, naive, cron)

      back = schedule.to_cron
      again = Hron::Schedule.from_cron(back)
      label = "#{cron} -> #{schedule} -> #{back}"
      assert_fires_as(again, naive, label) unless again.data == schedule.data
      naive_back = NaiveCron.new(back)
      assert_equal times, naive_back.times, label
      window_days.each { |d| assert_equal naive.fires_on(d), naive_back.fires_on(d), "#{label} on #{d}" }
      accepted += 1
    end
    assert_operator accepted, :>=, 60, "generated crons accepted"
  end

  def test_from_cron_is_exact_shard_0
    check_from_cron(0)
  end

  def test_from_cron_is_exact_shard_1
    check_from_cron(1)
  end

  def test_from_cron_is_exact_shard_2
    check_from_cron(2)
  end

  def test_from_cron_is_exact_shard_3
    check_from_cron(3)
  end

  TIME_LISTS = [
    "09:00",
    "00:00",
    "23:59",
    "09:00, 17:00",
    "17:00, 09:00, 09:00",
    "00:00, 12:00",
    "09:00, 13:00, 17:00",
    "09:00, 17:30",
    "00:05, 00:35",
    "00:00, 00:01, 00:02, 00:30",
    (0..12).flat_map { |h| [format("%02d:00", h), format("%02d:10", h)] }.join(", "),
    ((0..23).map { |h| format("%02d:00", h) } + ["23:59"]).join(", "),
    (0..23).map { |h| format("%02d:00", h) }.join(", "),
    (9..15).flat_map { |h| [format("%02d:00", h), format("%02d:30", h)] }.join(", "),
    (0..24).map { |m| format("09:%02d", m) }.join(", ")
  ].freeze
  # Each with the month it names, which a `during` must include.
  DAY_EXPRESSIONS = [
    ["every day", nil],
    ["every weekday", nil],
    ["every weekend", nil],
    ["every monday", nil],
    ["every sunday, saturday", nil],
    ["every friday, saturday, sunday", nil],
    ["every week on tuesday, friday", nil],
    ["every 1 day", nil],
    ["every month on the 1st", nil],
    ["every month on the 1st to 5th, 20th", nil],
    ["every month on the 31st", nil],
    ["every month on the 15th, 1st", nil],
    ["every month on the 1st to 31st", nil],
    ["every month on the last day", nil],
    ["every month on the last weekday", nil],
    ["every month on the nearest weekday to 1st", nil],
    ["every month on the nearest weekday to 31st", nil],
    ["every month on the nearest weekday to 15th", nil],
    ["every month on the first monday", nil],
    ["every month on the fifth friday", nil],
    ["every month on the last sunday", nil],
    ["every year on feb 29", "feb"],
    ["every year on dec 25", "dec"],
    ["every year on the 15th of march", "mar"],
    ["every year on the first monday of mar", "mar"],
    ["every year on the fifth monday of feb", "feb"],
    ["every year on the last friday of feb", "feb"],
    ["every year on the last weekday of dec", "dec"],
    ["on feb 14", "feb"],
    ["on feb 29", "feb"]
  ].freeze
  INTERVALS = [
    "every 30 min from 09:00 to 17:30",
    "every 15 min from 00:00 to 23:59",
    "every 2 hours from 00:00 to 23:59",
    "every 7 hours from 00:00 to 23:59",
    "every 45 min from 09:00 to 17:00",
    "every 20 min from 09:00 to 17:40",
    "every 1 minute from 00:00 to 23:59",
    "every 120 min from 01:00 to 23:00",
    "every 2147483647 hours from 00:00 to 23:59",
    "every 5 min from 10:00 to 10:30",
    "every 4 hours from 00:00 to 20:00",
    "every 1 hour from 09:05 to 17:05",
    "every 30 min from 09:00 to 17:00"
  ].freeze
  INTERVAL_DAYS_FILTERS = ["", " on weekday", " on weekend", " on monday, friday"].freeze
  DURING = [
    "",
    "",
    " during feb",
    " during dec",
    " during jan, jul",
    " during dec, jan, feb",
    " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec"
  ].freeze

  GeneratedSchedule = Data.define(:hron, :times, :own_month, :during)

  def generated_schedules
    rng = Rng.new(0x2545_f491_4f6c_dd1d)
    Array.new(240) do |i|
      during = rng.pick(DURING)
      if i % 3 == 0
        filter = rng.pick(INTERVAL_DAYS_FILTERS)
        interval = rng.pick(INTERVALS)
        GeneratedSchedule.new("#{interval}#{filter}#{during}", naive_interval_times(interval), nil, during)
      else
        days, own_month = DAY_EXPRESSIONS[rng.pick_index(DAY_EXPRESSIONS.length)]
        times = rng.pick(TIME_LISTS)
        GeneratedSchedule.new("#{days} at #{times}#{during}", times.split(", ").map { |t| naive_minute_of_day(t) }, own_month, during)
      end
    end
  end

  def naive_minute_of_day(time)
    hour, minute = time.split(":")
    Integer(hour, 10) * 60 + Integer(minute, 10)
  end

  def naive_interval_times(interval)
    words = interval.split(" ")
    every = Integer(words[1], 10)
    step = words[2].start_with?("hour") ? every * 60 : every
    from = naive_minute_of_day(words[4])
    (from..naive_minute_of_day(words[6])).select { |t| (t - from) % step == 0 }
  end

  # The reason to_cron must give, decided from the generated parts alone.
  def expected_to_cron_failure(generated)
    month = generated.own_month
    if month && !generated.during.empty? && !generated.during.include?(month)
      return "during excludes the schedule's month"
    end

    times = generated.times.uniq
    minutes = times.map { |t| t % 60 }.uniq.length
    hours = times.map { |t| t / 60 }.uniq.length
    "times are not every combination of their minutes and hours" if minutes * hours != times.length
  end

  def test_to_cron_is_exact
    accepted = 0
    rejected = 0
    generated_schedules.each do |generated|
      hron = generated.hron
      schedule = Hron::Schedule.parse(hron)
      reason = expected_to_cron_failure(generated)
      if reason
        assert_equal "not expressible as cron: #{reason}", cron_message { schedule.to_cron }, hron
        rejected += 1
        next
      end
      cron = schedule.to_cron
      naive = NaiveCron.new(cron)
      assert_fires_as(schedule, naive, "#{hron} -> #{cron}")
      accepted += 1

      times = naive.times
      label = "#{hron} -> #{cron} -> from_cron"
      if times.length > 24 && !(naive.days_carry_an_interval? && equal_gaps?(times))
        assert_equal too_many_times_message(times), cron_message { Hron::Schedule.from_cron(cron) }, label
        next
      end
      assert_fires_as(Hron::Schedule.from_cron(cron), naive, label)
    end
    assert_operator accepted, :>=, 60, "generated schedules converted"
    assert_operator rejected, :>=, 20, "generated schedules rejected"
  end

  def test_values_of_any_length_never_overflow
    long_zeros = "0" * 10_000
    huge = "9" * 10_000
    assert_equal "every day at 09:09", from_cron("#{long_zeros}9 #{long_zeros}9 * * *")
    assert_equal "day of week ordinal must be 1-5, got #{huge}", cron_message { from_cron("0 9 * * 1##{huge}") }
    assert_equal "day of month must be 1-31, got #{huge}", cron_message { from_cron("0 9 #{huge}W * *") }
    assert_equal "hour must be 0-23, got #{huge}", cron_message { from_cron("0 #{huge}-1 * * *") }
    assert_equal "every monday at 09:00", from_cron("0 9 * * 1-5/#{huge}")
    assert_equal "day of week step must be at least 1", cron_message { from_cron("0 9 * * */#{long_zeros}") }
    assert_equal "every sunday at 09:00", from_cron("0 9 * * 0-7/#{long_zeros}7")
  end

  def test_a_long_field_is_parsed_in_linear_time
    items = (["1"] * 200_000).join(",")
    assert_equal "every month on the 1st at 09:00", from_cron("0 9 #{items} * *")
    ranges = (["0-59/1"] * 50_000).join(",")
    assert_equal "every 1 minute from 09:00 to 09:59", from_cron("#{ranges} 9 * * *")
  end

  def test_text_outside_ascii_is_never_cron
    assert_equal "invalid hour: ٩", cron_message { from_cron("0 ٩ * * *") }
    assert_equal "invalid month: ſep", cron_message { from_cron("0 9 * ſep *") }
    assert_equal "invalid day of week: Kon", cron_message { from_cron("0 9 * * Kon") }
    assert_equal "expected 5 cron fields, got 6", cron_message { from_cron("\0 0 9 * * *") }
    assert_equal "invalid hour: �", cron_message { from_cron("0 \xFF * * *".b) }
    assert_equal "every day at 09:00", from_cron("0 9 * * *".encode("UTF-16LE"))
    assert_equal "invalid day of week: \u212Aon", cron_message { from_cron("0 9 * * \xE2\x84\xAAon".b) }
    assert_equal "every day at 09:00", from_cron("0 9 * * *".dup.force_encoding("UTF-7"))
  end

  def test_naive_matcher_agrees_with_known_dates
    fires = ->(cron, date) { NaiveCron.new(cron).fires_on(date) }
    assert fires.call("0 9 * 2 1#5", Date.new(2044, 2, 29))
    assert fires.call("0 9 1W * *", Date.new(2043, 8, 3)), "Saturday the 1st moves to Monday"
    assert fires.call("0 9 31W * *", Date.new(2043, 8, 31)), "Monday the 31st"
    assert fires.call("0 9 30W * *", Date.new(2044, 4, 29)), "Saturday the 30th moves to Friday"
    assert fires.call("0 9 31W * *", Date.new(2044, 7, 29)), "Sunday the 31st moves to Friday"
    refute fires.call("0 9 31W * *", Date.new(2044, 4, 30)), "April has no 31st"
    assert fires.call("0 9 LW * *", Date.new(2044, 4, 29))
    assert fires.call("0 9 * * 5L", Date.new(2044, 4, 29))
    refute fires.call("0 9 * * 5L", Date.new(2044, 4, 22))
  end

  def test_to_cron_of_a_built_schedule_with_interval_0_steps_by_1_of_its_unit_as_evaluation_does
    minutes = built(Hron::IntervalRepeat.new(0, Hron::IntervalUnit::MIN, Hron::TimeOfDay.new(9, 0), Hron::TimeOfDay.new(9, 2), nil))
    assert_equal "0-2 9 * * *", minutes.to_cron
    fires = minutes.next_n_from(utc(WINDOW_START, 9, 0), 2).map { |t| wall(t) }
    assert_equal [[WINDOW_START, [9, 1]], [WINDOW_START, [9, 2]]], fires

    hours = built(Hron::IntervalRepeat.new(0, Hron::IntervalUnit::HOURS, Hron::TimeOfDay.new(9, 0), Hron::TimeOfDay.new(10, 0), nil))
    assert_equal "0 9-10 * * *", hours.to_cron
    fires = hours.next_n_from(utc(WINDOW_START, 8, 0), 3).map { |t| wall(t) }
    assert_equal [[WINDOW_START, [9, 0]], [WINDOW_START, [10, 0]], [WINDOW_START + 1, [9, 0]]], fires
  end

  def test_to_cron_of_a_built_schedule_without_times_fails
    no_times = built(Hron::DayRepeat.new(1, Hron::DayFilterEvery.new, []))
    assert_equal "not expressible as cron: schedule has no times", cron_message { no_times.to_cron }
    reversed = built(Hron::IntervalRepeat.new(1, Hron::IntervalUnit::HOURS, Hron::TimeOfDay.new(9, 0), Hron::TimeOfDay.new(8, 0), nil))
    assert_equal "not expressible as cron: schedule has no times", cron_message { reversed.to_cron }
  end

  def test_to_cron_of_a_built_schedule_without_days_fails
    nine = [Hron::TimeOfDay.new(9, 0)]
    [
      Hron::DayRepeat.new(1, Hron::DayFilterDays.new([]), nine),
      Hron::WeekRepeat.new(1, [], nine),
      Hron::MonthRepeat.new(1, Hron::DaysTarget.new([]), nine),
      Hron::MonthRepeat.new(1, Hron::DaysTarget.new([Hron::DayRange.new(9, 5)]), nine),
      Hron::IntervalRepeat.new(1, Hron::IntervalUnit::HOURS, Hron::TimeOfDay.new(9, 0), Hron::TimeOfDay.new(17, 0), Hron::DayFilterDays.new([]))
    ].each do |expr|
      assert_equal "not expressible as cron: schedule has no days", cron_message { built(expr).to_cron }, expr.inspect
    end
  end

  def test_to_cron_reasons_around_no_days_and_no_times_follow_the_order
    empty_week = ->(interval) { Hron::WeekRepeat.new(interval, [], []) }
    assert_equal "not expressible as cron: multi-week repeats not supported", cron_message { built(empty_week.call(2)).to_cron }
    directional = Hron::MonthRepeat.new(1, Hron::NearestWeekdayTarget.new(1, Hron::NearestDirection::NEXT), [])
    assert_equal "not expressible as cron: directional nearest weekday not supported", cron_message { built(directional).to_cron }
    no_days_excluded_month = built(empty_week.call(1), during: [Hron::MonthName::MAR])
    assert_equal "not expressible as cron: schedule has no days", cron_message { no_days_excluded_month.to_cron }
    yearly_without_times = ->(during) { built(Hron::YearRepeat.new(1, Hron::YearDateTarget.new(Hron::MonthName::DEC, 25), []), during: during) }
    assert_equal "not expressible as cron: during excludes the schedule's month", cron_message { yearly_without_times.call([Hron::MonthName::JAN]).to_cron }
    assert_equal "not expressible as cron: schedule has no times", cron_message { yearly_without_times.call([]).to_cron }
  end
end
