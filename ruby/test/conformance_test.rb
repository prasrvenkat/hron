# frozen_string_literal: true

require_relative "test_helper"

class ConformanceTest < Minitest::Test
  SPEC = TestHelper.load_spec
  DEFAULT_NOW = TestHelper.parse_zoned(SPEC["now"])

  PARSE_SECTIONS = %w[
    day_repeat
    interval_repeat
    week_repeat
    month_repeat
    ordinal_repeat
    single_date
    year_repeat
    except_clause
    until_clause
    starting_clause
    during_clause
    timezone_clause
    combined_clauses
    case_insensitivity
  ].freeze

  EVAL_SECTIONS = %w[
    day_repeat
    interval_repeat
    month_repeat
    ordinal_repeat
    week_repeat
    single_date
    year_repeat
    except
    until
    except_and_until
    n_occurrences
    multi_time
    during
    day_ranges
    leap_year
    dst_spring_forward
    dst_fall_back
  ].freeze

  # ===========================================================================
  # Parse conformance tests
  # ===========================================================================

  PARSE_SECTIONS.each do |section|
    SPEC["parse"][section]["tests"].each do |tc|
      test_name = tc["name"] || tc["input"]
      define_method("test_parse_#{section}_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
        input = tc["input"]
        canonical = tc["canonical"]

        schedule = Hron::Schedule.parse(input)
        display = schedule.to_s
        assert_equal canonical, display, "Parse roundtrip failed for: #{input}"

        # Idempotency check
        s2 = Hron::Schedule.parse(canonical)
        assert_equal canonical, s2.to_s, "Idempotency failed for: #{canonical}"
      end
    end
  end

  # Parse error tests
  SPEC["parse_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["input"]
    define_method("test_parse_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      input = tc["input"]
      assert_raises(Hron::HronError) do
        Hron::Schedule.parse(input)
      end
    end
  end

  # ===========================================================================
  # Eval conformance tests
  # ===========================================================================

  EVAL_SECTIONS.each do |section|
    SPEC["eval"][section]["tests"].each do |tc|
      test_name = tc["name"] || tc["expression"]
      define_method("test_eval_#{section}_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
        schedule = Hron::Schedule.parse(tc["expression"])
        now = tc["now"] ? TestHelper.parse_zoned(tc["now"]) : DEFAULT_NOW

        # next (full timestamp)
        if tc["next"]
          result = schedule.next_from(now)
          if tc["next"].nil?
            assert_nil result
          else
            refute_nil result, "Expected next occurrence but got nil"
            # For comparison, we need to handle timezone formatting
            expected = tc["next"]
            # Extract timezone from expected
            match = expected.match(/\[(.+)\]$/)
            tz_name = match ? match[1] : "UTC"
            assert_equal expected, TestHelper.format_zoned(result, tz_name)
          end
        end

        # next_date (date-only check)
        if tc["next_date"]
          result = schedule.next_from(now)
          refute_nil result, "Expected next occurrence but got nil"
          assert_equal tc["next_date"], result.to_date.iso8601
        end

        # next_n (list of timestamps)
        if tc["next_n"]
          expected = tc["next_n"]
          n_count = tc["next_n_count"] || expected.length
          results = schedule.next_n_from(now, n_count)
          assert_equal expected.length, results.length

          expected.each_with_index do |e, j|
            match = e.match(/\[(.+)\]$/)
            tz_name = match ? match[1] : "UTC"
            assert_equal e, TestHelper.format_zoned(results[j], tz_name), "next_n_from[#{j}] mismatch"
          end
        end

        # next_n_length (just check count)
        next unless tc["next_n_length"]

        expected_len = tc["next_n_length"]
        n_count_len = tc["next_n_count"]
        results = schedule.next_n_from(now, n_count_len)
        assert_equal expected_len, results.length
      end
    end
  end

  # ===========================================================================
  # Eval matches conformance tests
  # ===========================================================================

  SPEC["eval"]["matches"]["tests"].each do |tc|
    test_name = tc["name"] || tc["expression"]
    define_method("test_matches_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      schedule = Hron::Schedule.parse(tc["expression"])
      dt = TestHelper.parse_zoned(tc["datetime"])
      result = schedule.matches(dt)
      assert_equal tc["expected"], result
    end
  end

  # ===========================================================================
  # Cron conformance tests
  # ===========================================================================

  # to_cron tests
  SPEC["cron"]["to_cron"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_method("test_to_cron_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      schedule = Hron::Schedule.parse(tc["hron"])
      assert_equal tc["cron"], schedule.to_cron
    end
  end

  # to_cron error tests
  SPEC["cron"]["to_cron_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_method("test_to_cron_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      schedule = Hron::Schedule.parse(tc["hron"])
      assert_raises(Hron::HronError) do
        schedule.to_cron
      end
    end
  end

  # from_cron tests
  SPEC["cron"]["from_cron"]["tests"].each do |tc|
    test_name = tc["name"] || tc["cron"]
    define_method("test_from_cron_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      schedule = Hron::Schedule.from_cron(tc["cron"])
      assert_equal tc["hron"], schedule.to_s
    end
  end

  # from_cron error tests
  SPEC["cron"]["from_cron_errors"]["tests"].each do |tc|
    test_name = tc["name"] || tc["cron"]
    define_method("test_from_cron_error_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      assert_raises(Hron::HronError) do
        Hron::Schedule.from_cron(tc["cron"])
      end
    end
  end

  # roundtrip tests
  SPEC["cron"]["roundtrip"]["tests"].each do |tc|
    test_name = tc["name"] || tc["hron"]
    define_method("test_cron_roundtrip_#{test_name.gsub(/[^a-zA-Z0-9_]/, "_")}") do
      schedule = Hron::Schedule.parse(tc["hron"])
      cron1 = schedule.to_cron
      back = Hron::Schedule.from_cron(cron1)
      cron2 = back.to_cron
      assert_equal cron1, cron2
    end
  end
end
