# frozen_string_literal: true

require_relative "test_helper"

# The search's footing: a slot in a spring-forward gap sits at the instant its gap ends, and a
# slot a fall-back repeats takes its first pass, so slot keys never decrease in wall-clock order
# and one binary search finds where they part. A key out of order would otherwise show only as
# a search that never ends.
class SearchTest < Minitest::Test
  WallClock = Hron::Evaluator.const_get(:WallClock)

  # A gap per zone: its first wall time, the first wall time after it, and the instant it ends,
  # as the zone's transition data gives them. Wall times are written as UTC Times.
  GAPS = {
    "new-york" => ["America/New_York", Time.utc(2026, 3, 8, 2, 0), Time.utc(2026, 3, 8, 3, 0), Time.utc(2026, 3, 8, 7, 0)],
    "lord-howe-half-hour" => ["Australia/Lord_Howe", Time.utc(2026, 10, 4, 2, 0), Time.utc(2026, 10, 4, 2, 30), Time.utc(2026, 10, 3, 15, 30)],
    "apia-whole-day" => ["Pacific/Apia", Time.utc(2011, 12, 30, 0, 0), Time.utc(2011, 12, 31, 0, 0), Time.utc(2011, 12, 30, 10, 0)],
    "nuuk-before-midnight" => ["America/Nuuk", Time.utc(2026, 3, 28, 23, 0), Time.utc(2026, 3, 29, 0, 0), Time.utc(2026, 3, 29, 1, 0)],
    "santiago-at-midnight" => ["America/Santiago", Time.utc(2026, 9, 6, 0, 0), Time.utc(2026, 9, 6, 1, 0), Time.utc(2026, 9, 6, 4, 0)]
  }.freeze

  # An overlap per zone: its first repeated wall time, the first wall time after it, and the
  # offset of its first pass in seconds.
  OVERLAPS = {
    "new-york" => ["America/New_York", Time.utc(2026, 11, 1, 1, 0), Time.utc(2026, 11, 1, 2, 0), -4 * 3600],
    "santiago-across-midnight" => ["America/Santiago", Time.utc(2026, 4, 4, 23, 0), Time.utc(2026, 4, 5, 0, 0), -3 * 3600]
  }.freeze

  AROUND = 3 * 3600

  def minutes(from, to)
    (from.to_i...to.to_i).step(60).map { |seconds| Time.at(seconds).utc }
  end

  def slot(wall, zone)
    date = Date.new(wall.year, wall.month, wall.day, Date::GREGORIAN)
    WallClock.slot_on(date, (wall.hour * 60) + wall.min, TZInfo::Timezone.get(zone))
  end

  def assert_keys_never_decrease(slots)
    keys = slots.map(&:key)
    assert_equal keys.sort, keys
  end

  GAPS.each do |name, (zone, first_in_gap, first_after, ends_at)|
    define_method(:"test_a_slot_in_a_gap_has_no_instant_and_sits_where_the_gap_ends_#{name}") do
      minutes(first_in_gap, first_after).each do |wall|
        in_gap = slot(wall, zone)
        assert_nil in_gap.instant, wall
        assert_equal ends_at, in_gap.key, wall
      end
    end

    define_method(:"test_slot_keys_never_decrease_across_a_gap_#{name}") do
      walls = minutes(first_in_gap - AROUND, first_after + AROUND)
      slots = walls.map { |wall| slot(wall, zone) }
      assert_keys_never_decrease(slots)
      walls.zip(slots).each do |wall, outside|
        next if wall >= first_in_gap && wall < first_after

        assert_equal outside.key, outside.instant, wall
      end
      assert_equal ends_at, slots[walls.index(first_after)].key
    end
  end

  OVERLAPS.each do |name, (zone, first_repeated, first_after, first_pass_offset)|
    define_method(:"test_slot_keys_never_decrease_across_an_overlap_#{name}") do
      walls = minutes(first_repeated - AROUND, first_after + AROUND)
      slots = walls.map { |wall| slot(wall, zone) }
      assert_keys_never_decrease(slots)
      slots.each_with_index { |repeated, i| assert_equal repeated.key, repeated.instant, walls[i] }
      minutes(first_repeated, first_after).each do |wall|
        assert_equal wall - first_pass_offset, slot(wall, zone).instant, wall
      end
    end
  end
end
