# frozen_string_literal: true

require_relative "test_helper"

class IteratorTest < Minitest::Test
  def test_occurrences_is_lazy
    # An unbounded schedule should not hang or OOM when creating the enumerator
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    iter = schedule.occurrences(from)

    results = iter.first(1)
    assert_equal 1, results.length
  end

  def test_between_is_lazy
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-12-31T23:59:00+00:00[UTC]")

    iter = schedule.between(from, to)

    results = iter.first(3)
    assert_equal 3, results.length
  end

  def test_occurrences_early_termination_with_take
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).take(5).to_a

    assert_equal 5, results.length
  end

  def test_occurrences_early_termination_with_take_while
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    cutoff = TestHelper.parse_zoned("2026-02-05T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).take_while { |dt| dt < cutoff }.to_a

    # Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
    assert_equal 4, results.length
  end

  def test_occurrences_early_termination_with_break
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = []
    schedule.occurrences(from).each do |dt|
      results << dt
      break if results.length >= 5
    end

    assert_equal 5, results.length
  end

  def test_occurrences_find_with_detect
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    saturday = schedule.occurrences(from).detect { |dt| dt.wday == 6 }

    # Feb 7, 2026 is a Saturday
    assert_equal 7, saturday.day
  end

  def test_occurrences_returns_enumerator
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    iter = schedule.occurrences(from)

    assert_kind_of Enumerator, iter
  end

  def test_between_returns_enumerator
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-05T00:00:00+00:00[UTC]")

    iter = schedule.between(from, to)

    assert_kind_of Enumerator, iter
  end

  def test_lazy_chaining
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    lazy = schedule.occurrences(from).lazy
    assert_kind_of Enumerator::Lazy, lazy
  end

  def test_works_with_select_filter
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    weekends = schedule.occurrences(from)
      .first(14)
      .select { |dt| dt.wday == 0 || dt.wday == 6 }

    # 2 weekends in 2 weeks = 4 days
    assert_equal 4, weekends.length
  end

  def test_works_with_map
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    days = schedule.occurrences(from).first(5).map(&:day)

    assert_equal [1, 2, 3, 4, 5], days
  end

  def test_works_with_drop
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).drop(5).first(3)

    assert_equal 3, results.length
    assert_equal 6, results[0].day
    assert_equal 7, results[1].day
    assert_equal 8, results[2].day
  end

  def test_between_works_with_count
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-10T23:59:00+00:00[UTC]")

    count = schedule.between(from, to).count

    # Feb 1-10 inclusive = 10 days
    assert_equal 10, count
  end

  def test_between_collect_to_array
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-10T23:59:00+00:00[UTC]")

    results = schedule.between(from, to).to_a

    assert_equal 10, results.length
    assert results.all? { |dt| dt.is_a?(Time) }
  end

  def test_works_with_each_with_index
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    indexed = []
    schedule.occurrences(from).first(3).each_with_index do |dt, i|
      indexed << [i, dt.day]
    end

    assert_equal [[0, 1], [1, 2], [2, 3]], indexed
  end

  def test_occurrences_collect_to_array
    schedule = Hron::Schedule.parse("every day at 09:00 until 2026-02-05 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).to_a

    assert_equal 5, results.length # Feb 1-5
  end

  def test_between_collect_to_array2
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-07T23:59:00+00:00[UTC]")

    results = schedule.between(from, to).to_a

    assert_equal 7, results.length
  end

  def test_occurrences_each_with_break
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    count = 0
    schedule.occurrences(from).each do |dt|
      count += 1
      break if dt.day >= 5
    end

    assert_equal 5, count
  end

  def test_between_each_loop
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-03T23:59:00+00:00[UTC]")

    days = []
    schedule.between(from, to).each do |dt|
      days << dt.day
    end

    assert_equal [1, 2, 3], days
  end

  def test_occurrences_empty_when_past_until
    schedule = Hron::Schedule.parse("every day at 09:00 until 2026-01-01 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).first(10)

    assert_equal 0, results.length
  end

  def test_between_empty_range
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T12:00:00+00:00[UTC]")
    to = TestHelper.parse_zoned("2026-02-01T13:00:00+00:00[UTC]")

    results = schedule.between(from, to).to_a

    assert_equal 0, results.length
  end

  def test_occurrences_single_date_terminates
    schedule = Hron::Schedule.parse("on 2026-02-14 at 14:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    # Request many but should only get 1
    results = schedule.occurrences(from).first(100)

    assert_equal 1, results.length
  end

  def test_occurrences_preserves_timezone
    schedule = Hron::Schedule.parse("every day at 09:00 in America/New_York")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00-05:00[America/New_York]")

    results = schedule.occurrences(from).first(3)

    results.each do |dt|
      formatted = TestHelper.format_zoned(dt, "America/New_York")
      assert formatted.include?("[America/New_York]"), "Expected America/New_York timezone"
      assert formatted.include?("T09:00:00"), "Expected 09:00 time"
    end
  end

  def test_between_handles_dst_transition
    # March 8, 2026 is DST spring forward in America/New_York
    # 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
    schedule = Hron::Schedule.parse("every day at 02:30 in America/New_York")
    from = TestHelper.parse_zoned("2026-03-07T00:00:00-05:00[America/New_York]")
    to = TestHelper.parse_zoned("2026-03-10T00:00:00-04:00[America/New_York]")

    results = schedule.between(from, to).to_a

    # Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
    assert_equal 3, results.length

    formatted0 = TestHelper.format_zoned(results[0], "America/New_York")
    formatted1 = TestHelper.format_zoned(results[1], "America/New_York")
    formatted2 = TestHelper.format_zoned(results[2], "America/New_York")

    assert formatted0.include?("T02:30:00"), "Mar 7 should be 02:30, got #{formatted0}"
    assert formatted1.include?("T03:30:00"), "Mar 8 should be 03:30 (DST shift), got #{formatted1}"
    assert formatted2.include?("T02:30:00"), "Mar 9 should be 02:30, got #{formatted2}"
  end

  def test_occurrences_multiple_times_per_day
    schedule = Hron::Schedule.parse("every day at 09:00, 12:00, 17:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    results = schedule.occurrences(from).first(9) # 3 days worth

    assert_equal 9, results.length
    assert_equal 9, results[0].hour
    assert_equal 12, results[1].hour
    assert_equal 17, results[2].hour
  end

  def test_complex_chain
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    weekday_days = schedule.occurrences(from)
      .first(14) # Two weeks to ensure we have enough
      .select { |dt| dt.wday.between?(1, 5) } # Monday-Friday
      .first(5)
      .map(&:day)

    # Feb 2026: 2,3,4,5,6 are Mon-Fri
    assert_equal [2, 3, 4, 5, 6], weekday_days
  end

  def test_manual_next_calls
    schedule = Hron::Schedule.parse("every day at 09:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    iter = schedule.occurrences(from)

    first = iter.next
    assert_equal 1, first.day

    second = iter.next
    assert_equal 2, second.day

    third = iter.next
    assert_equal 3, third.day
  end

  def test_stopiteration_on_exhaustion
    schedule = Hron::Schedule.parse("on 2026-02-14 at 14:00 in UTC")
    from = TestHelper.parse_zoned("2026-02-01T00:00:00+00:00[UTC]")

    iter = schedule.occurrences(from)

    first = iter.next
    assert_equal 14, first.day

    assert_raises(StopIteration) { iter.next }
  end
end
