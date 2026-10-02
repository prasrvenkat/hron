# frozen_string_literal: true

require_relative "test_helper"

# spec/README.md, "Timestamps and counts".
class TimestampsTest < Minitest::Test
  NEW_YORK = Hron::Schedule.parse("every day at 09:00 in America/New_York")
  ZONELESS = Hron::Schedule.parse("every day at 09:00")

  # 2026-02-06 21:00 in Tokyo is 07:00 in New York and 12:00 UTC.
  def tokyo_now
    Time.new(2026, 2, 6, 21, 0, 0, "+09:00")
  end

  def tokyo_to
    Time.new(2026, 2, 8, 0, 0, 0, "+09:00")
  end

  def every_method(schedule, now, to)
    {
      next_from: -> { schedule.next_from(now) },
      previous_from: -> { schedule.previous_from(now) },
      next_n_from: -> { schedule.next_n_from(now, 2) },
      matches: -> { schedule.matches(now) },
      occurrences: -> { schedule.occurrences(now).first(2) },
      between: -> { schedule.between(now, to).to_a }
    }
  end

  def every_result(schedule, now, to)
    [schedule.next_from(now), schedule.previous_from(now), *schedule.next_n_from(now, 2),
      *schedule.occurrences(now).first(2), *schedule.between(now, to).to_a]
  end

  def test_no_method_changes_the_time_it_is_given
    every_method(NEW_YORK, nil, nil).each_key do |name|
      now = tokyo_now
      to = tokyo_to
      every_method(NEW_YORK, now, to).fetch(name).call
      [now, to].each do |time|
        refute time.utc?, name
        assert_equal 9 * 3600, time.utc_offset, name
      end
    end
  end

  def test_every_method_takes_a_frozen_time
    now = tokyo_now.freeze
    to = tokyo_to.freeze
    every_method(NEW_YORK, now, to).each do |name, call|
      call.call
    rescue FrozenError => e
      flunk "#{name}: #{e.message}"
    end
    assert_equal "2026-02-06T09:00:00-05:00[America/New_York]", TestHelper.format_zoned(NEW_YORK.next_from(now))
  end

  def test_results_are_in_the_schedules_zone
    results = every_result(NEW_YORK, tokyo_now, tokyo_to)
    assert_equal 8, results.size
    results.each do |result|
      assert_kind_of TZInfo::Timezone, result.zone
      assert_equal "America/New_York", result.zone.identifier
      assert_equal(-5 * 3600, result.utc_offset)
      assert_equal 9, result.hour
    end
    assert_equal "2026-02-06T09:00:00-05:00", NEW_YORK.next_from(tokyo_now).iso8601
  end

  def test_a_zone_link_keeps_its_own_name
    result = Hron::Schedule.parse("every day at 09:00 in us/eastern").next_from(tokyo_now)
    assert_equal "US/Eastern", result.zone.identifier
    assert_equal "2026-02-06T09:00:00-05:00", result.iso8601
  end

  def test_results_take_the_offset_in_force_at_their_instant
    result = NEW_YORK.next_from(Time.utc(2026, 7, 1))
    assert_equal "2026-07-01T09:00:00-04:00", result.iso8601
  end

  def test_results_without_a_zone_are_utc
    results = every_result(ZONELESS, tokyo_now, tokyo_to)
    assert_equal 7, results.size
    results.each do |result|
      assert result.utc?
      assert_equal "UTC", result.zone
    end
    assert_equal "2026-02-07T09:00:00Z", ZONELESS.next_from(tokyo_now).iso8601
  end

  def test_an_explicit_utc_zone_is_the_tzinfo_zone
    result = Hron::Schedule.parse("every day at 09:00 in UTC").next_from(tokyo_now)
    assert_equal "UTC", result.zone.identifier
    assert_equal "2026-02-07T09:00:00+00:00", result.iso8601
  end

  def test_readme_usage_prints_zoned_times
    readme = File.read(File.expand_path("../README.md", __dir__))
    usage = readme[/^## Usage\n\n```ruby\n(.*?)^```/m, 1]
    out, = capture_io { Object.new.instance_eval(usage) }
    assert_equal <<~PRINTED, out
      2026-02-06 09:00:00 -0500
      2026-02-06 09:00:00 -0500
      2026-02-09 09:00:00 -0500
      2026-02-10 09:00:00 -0500
      0 9 * * *
      every 30 min from 00:00 to 23:59
      every weekday at 09:00 in America/New_York
      timezone must be UTC or an Area/Location name such as America/New_York, got EST
    PRINTED
  end

  NOT_TIMES = {
    "a String" => "2026-02-06T12:00:00Z",
    "a Date" => Date.new(2026, 2, 6),
    "a DateTime" => DateTime.new(2026, 2, 6, 12),
    "nil" => nil
  }.freeze

  NOT_TIMES.each do |label, value|
    define_method(:"test_#{label.tr(" ", "_")}_is_a_type_error_wherever_a_time_goes") do
      now = Time.utc(2026, 2, 6, 12)
      calls = {
        "next_from" => -> { NEW_YORK.next_from(value) },
        "previous_from" => -> { NEW_YORK.previous_from(value) },
        "next_n_from" => -> { NEW_YORK.next_n_from(value, 2) },
        "matches" => -> { NEW_YORK.matches(value) },
        "occurrences" => -> { NEW_YORK.occurrences(value) },
        "between from" => -> { NEW_YORK.between(value, now) },
        "between to" => -> { NEW_YORK.between(now, value) }
      }
      calls.each do |name, call|
        error = assert_raises(TypeError, name) { call.call }
        assert_match(/must be a Time, not #{value.class}/, error.message, name)
      end
    end
  end

  def test_n_that_is_not_an_integer_is_a_type_error
    [1.5, "2", nil, 2r].each do |n|
      error = assert_raises(TypeError, n.inspect) { NEW_YORK.next_n_from(tokyo_now, n) }
      assert_equal "n must be an Integer, not #{n.class}", error.message
    end
  end

  def test_n_of_zero_or_less_is_empty
    [0, -1, -(2**64)].each do |n|
      assert_equal [], NEW_YORK.next_n_from(tokyo_now, n), n
    end
  end

  def test_n_past_a_machine_integer_returns_every_occurrence
    once = Hron::Schedule.parse("on 2026-03-01 at 09:00")
    assert_equal [Time.utc(2026, 3, 1, 9)], once.next_n_from(tokyo_now, 2**64)

    millennial = Hron::Schedule.parse("every 1000 years on jan 1 at 00:00")
    assert_equal (2970..9970).step(1000).map { |year| Time.utc(year) }, millennial.next_n_from(tokyo_now, 2**64)
  end

  def test_n_caps_the_count
    assert_equal 3, NEW_YORK.next_n_from(tokyo_now, 3).size
  end
end
