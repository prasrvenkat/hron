# frozen_string_literal: true

require_relative "test_helper"

class ConformanceTest < Minitest::Test
  SPEC = TestHelper.load_spec
  DEFAULT_NOW = TestHelper.parse_zoned(SPEC["now"])

  TOP_LEVEL_KEYS = %w[
    $schema version description now _eval_assertion_types _behavioral_notes
    parse parse_errors eval cron invariants
  ].freeze

  PARSE_SECTIONS = %w[
    day_repeat
    interval_repeat
    week_repeat
    month_repeat
    single_date
    year_repeat
    except_clause
    until_clause
    starting_clause
    during_clause
    timezone_clause
    combined_clauses
    case_insensitivity
    ordinal_in_dates
  ].freeze

  NEXT_SECTIONS = %w[
    day_repeat interval_repeat month_repeat week_repeat single_date year_repeat
    except until except_and_until n_occurrences multi_time during day_ranges
    leap_year dst_spring_forward dst_fall_back timezone_default contradictory edge_cases
  ].freeze
  NEXT_FIELDS = %w[next next_date next_n next_n_length].freeze
  EVAL_SECTIONS = NEXT_SECTIONS + %w[matches previous_from occurrences between]
  CRON_SECTIONS = %w[to_cron to_cron_errors from_cron from_cron_errors roundtrip].freeze

  def test_spec_has_no_section_this_runner_skips
    assert_empty SPEC.keys - TOP_LEVEL_KEYS, "unknown top-level sections"
    assert_empty SPEC["parse"].keys - ["description"] - PARSE_SECTIONS, "unknown parse sections"
    assert_empty SPEC["eval"].keys - ["description"] - EVAL_SECTIONS, "unknown eval sections"
    assert_empty SPEC["cron"].keys - CRON_SECTIONS, "unknown cron sections"
  end

  LABEL_FIELDS = %w[name description].freeze

  # A second case with the same name would silently replace the first test, so that raises.
  def self.define_case(name, tc, fields, &body)
    raise ArgumentError, "duplicate conformance case: #{name}" if method_defined?(name)

    define_method(name) do
      assert_empty tc.keys - fields - LABEL_FIELDS, "case fields this runner does not check"
      instance_exec(&body)
    end
  end

  def self.case_name(tc, fallback_key)
    (tc["name"] || tc[fallback_key]).gsub(/[^a-zA-Z0-9_]/, "_")
  end

  def format_like(time, expected)
    TestHelper.format_zoned(time, expected[/\[(.+)\]$/, 1] || "UTC")
  end

  def assert_occurrence(expected, actual, label)
    return assert_nil actual, label if expected.nil?

    refute_nil actual, label
    assert_equal expected, format_like(actual, expected), label
  end

  def assert_occurrences(expected, actual, label)
    sample = expected.first || "[UTC]"
    assert_equal expected, actual.map { |t| format_like(t, sample) }, label
  end

  def require_assertion(tc, fields)
    flunk "no assertion field this runner understands (expected one of #{fields.join(", ")})" if (tc.keys & fields).empty?
  end

  PARSE_SECTIONS.each do |section|
    SPEC["parse"][section]["tests"].each do |tc|
      test_name = tc["name"] || tc["input"]
      define_case("test_parse_#{section}_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[input canonical]) do
        input = tc["input"]
        canonical = tc["canonical"]

        schedule = Hron::Schedule.parse(input)
        display = schedule.to_s
        assert_equal canonical, display, "Parse roundtrip failed for: #{input}"

        s2 = Hron::Schedule.parse(canonical)
        assert_equal canonical, s2.to_s, "Idempotency failed for: #{canonical}"
      end
    end
  end

  SPEC["parse_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["input"]
    define_case("test_parse_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[input error_contains]) do
      error = assert_raises(Hron::HronError) { Hron::Schedule.parse(tc["input"]) }
      assert_includes error.message, tc["error_contains"] if tc.key?("error_contains")
      assert_equal false, Hron::Schedule.validate(tc["input"]), "validate"
    end
  end

  NEXT_SECTIONS.each do |section|
    SPEC["eval"][section]["tests"].each do |tc|
      define_case("test_eval_#{section}_#{case_name(tc, "expression")}", tc, %w[expression now next_n_count] + NEXT_FIELDS) do
        require_assertion(tc, NEXT_FIELDS)
        schedule = Hron::Schedule.parse(tc["expression"])
        now = tc["now"] ? TestHelper.parse_zoned(tc["now"]) : DEFAULT_NOW

        assert_occurrence tc["next"], schedule.next_from(now), "next" if tc.key?("next")
        if tc.key?("next_date")
          result = schedule.next_from(now)
          next_date = result && TestHelper.format_zoned(result, schedule.timezone || "UTC")[0, 10]
          tc["next_date"].nil? ? assert_nil(next_date, "next_date") : assert_equal(tc["next_date"], next_date, "next_date")
        end

        if tc.key?("next_n")
          count = tc["next_n_count"] || tc["next_n"].length
          assert_occurrences tc["next_n"], schedule.next_n_from(now, count), "next_n"
        end

        if tc.key?("next_n_length")
          assert_equal tc["next_n_length"], schedule.next_n_from(now, tc["next_n_count"]).length, "next_n_length"
        end
      end
    end
  end

  SPEC["eval"]["previous_from"]["tests"].each do |tc|
    define_case("test_previous_from_#{case_name(tc, "expression")}", tc, %w[expression now expected]) do
      require_assertion(tc, %w[expected])
      schedule = Hron::Schedule.parse(tc["expression"])
      now = TestHelper.parse_zoned(tc["now"])
      assert_occurrence tc["expected"], schedule.previous_from(now), "previous_from"
    end
  end

  SPEC["eval"]["matches"]["tests"].each do |tc|
    define_case("test_matches_#{case_name(tc, "expression")}", tc, %w[expression datetime expected]) do
      require_assertion(tc, %w[expected])
      schedule = Hron::Schedule.parse(tc["expression"])
      dt = TestHelper.parse_zoned(tc["datetime"])
      assert_equal tc["expected"], schedule.matches(dt)
    end
  end

  SPEC["eval"]["occurrences"]["tests"].each do |tc|
    define_case("test_occurrences_#{case_name(tc, "expression")}", tc, %w[expression from take expected]) do
      require_assertion(tc, %w[expected])
      schedule = Hron::Schedule.parse(tc["expression"])
      from = TestHelper.parse_zoned(tc["from"])
      assert_occurrences tc["expected"], schedule.occurrences(from).first(tc["take"]), "occurrences"
    end
  end

  SPEC["eval"]["between"]["tests"].each do |tc|
    define_case("test_between_#{case_name(tc, "expression")}", tc, %w[expression from to expected expected_count]) do
      require_assertion(tc, %w[expected expected_count])
      schedule = Hron::Schedule.parse(tc["expression"])
      results = schedule.between(TestHelper.parse_zoned(tc["from"]), TestHelper.parse_zoned(tc["to"])).to_a

      assert_occurrences tc["expected"], results, "between" if tc.key?("expected")
      assert_equal tc["expected_count"], results.length, "between count" if tc.key?("expected_count")
    end
  end

  INVARIANTS = SPEC["invariants"]

  INVARIANTS["tests"].each do |tc|
    define_case("test_invariant_#{tc["name"].gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[expression now]) do
      schedule = Hron::Schedule.parse(tc["expression"])
      now = TestHelper.parse_zoned(tc["now"])
      INVARIANTS["rules"].each_key do |rule|
        send("check_#{rule}", schedule, now, "#{tc["name"]} (#{tc["expression"]}): #{rule}")
      end
    end
  end

  def invariant_next_n(schedule, now)
    schedule.next_n_from(now, INVARIANTS["count"])
  end

  def check_next_matches(schedule, now, label)
    t = schedule.next_from(now)
    assert_equal true, schedule.matches(t), "#{label}: matches(#{t.iso8601})" if t
  end

  def check_next_after_now(schedule, now, label)
    t = schedule.next_from(now)
    assert_operator t, :>, now, label if t
  end

  def check_next_n_chain(schedule, now, label)
    list = invariant_next_n(schedule, now)
    first = schedule.next_from(now)
    return assert_empty list, label if first.nil?

    assert_equal first, list.first, "#{label}: first element"
    list.each_cons(2) do |a, b|
      assert_operator a, :<, b, "#{label}: not increasing"
      assert_equal schedule.next_from(a), b, "#{label}: next_from(#{a.iso8601})"
    end
  end

  def check_occurrences_prefix(schedule, now, label)
    count = INVARIANTS["count"]
    assert_equal invariant_next_n(schedule, now), schedule.occurrences(now).first(count), label
  end

  def check_between_window(schedule, now, label)
    list = invariant_next_n(schedule, now)
    assert_equal list, schedule.between(now, list.last).to_a, label unless list.empty?
  end

  def check_prev_inverse(schedule, now, label)
    invariant_next_n(schedule, now).each_cons(2) do |a, b|
      assert_equal a, schedule.previous_from(b), "#{label}: previous_from(#{b.iso8601})"
    end
  end

  def check_prev_before_now(schedule, now, label)
    p = schedule.previous_from(now)
    return unless p

    assert_operator p, :<, now, label
    assert_equal true, schedule.matches(p), "#{label}: matches(#{p.iso8601})"
    after = schedule.next_from(p)
    assert(after.nil? || after >= now, "#{label}: next_from(#{p.iso8601}) is #{after&.iso8601}")
  end

  def check_display_roundtrip(schedule, _now, label)
    display = schedule.to_s
    assert_equal display, Hron::Schedule.parse(display).to_s, label
  end

  SPEC["cron"]["to_cron"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_case("test_to_cron_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[hron cron]) do
      schedule = Hron::Schedule.parse(tc["hron"])
      assert_equal tc["cron"], schedule.to_cron
    end
  end

  SPEC["cron"]["to_cron_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_case("test_to_cron_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[hron]) do
      schedule = Hron::Schedule.parse(tc["hron"])
      assert_raises(Hron::HronError) do
        schedule.to_cron
      end
    end
  end

  SPEC["cron"]["from_cron"]["tests"].each do |tc|
    test_name = tc["name"] || tc["cron"]
    define_case("test_from_cron_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[cron hron]) do
      schedule = Hron::Schedule.from_cron(tc["cron"])
      assert_equal tc["hron"], schedule.to_s
    end
  end

  SPEC["cron"]["from_cron_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["cron"]
    define_case("test_from_cron_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[cron]) do
      assert_raises(Hron::HronError) do
        Hron::Schedule.from_cron(tc["cron"])
      end
    end
  end

  SPEC["cron"]["roundtrip"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_case("test_cron_roundtrip_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}", tc, %w[hron]) do
      schedule = Hron::Schedule.parse(tc["hron"])
      cron1 = schedule.to_cron
      back = Hron::Schedule.from_cron(cron1)
      cron2 = back.to_cron
      assert_equal cron1, cron2
    end
  end
end
