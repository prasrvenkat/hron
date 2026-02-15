# frozen_string_literal: true

require_relative "test_helper"

class ApiConformanceTest < Minitest::Test
  API_SPEC = TestHelper.load_api_spec
  SCHEDULE_SPEC = API_SPEC["schedule"]

  # Map camelCase spec names to Ruby equivalents
  STATIC_METHOD_MAP = {
    "parse" => "parse",
    "fromCron" => "from_cron",
    "validate" => "validate"
  }.freeze

  INSTANCE_METHOD_MAP = {
    "nextFrom" => "next_from",
    "nextNFrom" => "next_n_from",
    "matches" => "matches",
    "occurrences" => "occurrences",
    "between" => "between",
    "toCron" => "to_cron",
    "toString" => "to_s"
  }.freeze

  GETTER_MAP = {
    "timezone" => "timezone"
  }.freeze

  # ===========================================================================
  # Static methods
  # ===========================================================================

  def test_parse
    schedule = Hron::Schedule.parse("every day at 09:00")
    assert_instance_of Hron::Schedule, schedule
  end

  def test_from_cron
    schedule = Hron::Schedule.from_cron("0 9 * * *")
    assert_instance_of Hron::Schedule, schedule
  end

  def test_validate
    assert_equal true, Hron::Schedule.validate("every day at 09:00")
    assert_equal false, Hron::Schedule.validate("not a schedule")
  end

  # ===========================================================================
  # Instance methods
  # ===========================================================================

  def setup
    @schedule = Hron::Schedule.parse("every day at 09:00")
    @now = Time.utc(2026, 2, 6, 12, 0, 0)
  end

  def test_next_from
    result = @schedule.next_from(@now)
    refute_nil result
    assert_kind_of Time, result
  end

  def test_next_n_from
    results = @schedule.next_n_from(@now, 3)
    assert_kind_of Array, results
    assert_equal 3, results.length
    results.each { |r| assert_kind_of Time, r }
  end

  def test_matches
    result = @schedule.matches(@now)
    assert_includes [true, false], result
  end

  def test_to_cron
    cron = @schedule.to_cron
    assert_kind_of String, cron
  end

  def test_to_string
    display = @schedule.to_s
    assert_kind_of String, display
    assert_equal "every day at 09:00", display
  end

  # ===========================================================================
  # Getters
  # ===========================================================================

  def test_timezone_none
    schedule = Hron::Schedule.parse("every day at 09:00")
    assert_nil schedule.timezone
  end

  def test_timezone_present
    schedule = Hron::Schedule.parse("every day at 09:00 in America/New_York")
    assert_equal "America/New_York", schedule.timezone
  end

  # ===========================================================================
  # Spec coverage
  # ===========================================================================

  def test_all_static_methods_exist
    SCHEDULE_SPEC["staticMethods"].each do |method|
      ruby_name = STATIC_METHOD_MAP[method["name"]]
      refute_nil ruby_name, "unmapped spec static method: #{method["name"]}"
      assert_respond_to Hron::Schedule, ruby_name, "Schedule missing static method: #{ruby_name}"
    end
  end

  def test_all_instance_methods_exist
    instance = Hron::Schedule.parse("every day at 09:00")
    SCHEDULE_SPEC["instanceMethods"].each do |method|
      ruby_name = INSTANCE_METHOD_MAP[method["name"]]
      refute_nil ruby_name, "unmapped spec instance method: #{method["name"]}"
      assert_respond_to instance, ruby_name, "Schedule missing instance method: #{ruby_name}"
    end
  end

  def test_all_getters_exist
    instance = Hron::Schedule.parse("every day at 09:00")
    SCHEDULE_SPEC["getters"].each do |getter|
      ruby_name = GETTER_MAP[getter["name"]]
      refute_nil ruby_name, "unmapped spec getter: #{getter["name"]}"
      assert_respond_to instance, ruby_name, "Schedule missing getter: #{ruby_name}"
    end
  end

  def test_error_kinds_match_spec
    spec_kinds = Set.new(API_SPEC["error"]["kinds"])
    assert_equal Set.new(%w[lex parse eval cron]), spec_kinds
  end

  def test_error_constructors_exist
    API_SPEC["error"]["constructors"].each do |kind|
      assert_respond_to Hron::HronError, kind, "HronError missing constructor: #{kind}"
    end
  end

  def test_error_display_rich_exists
    API_SPEC["error"]["methods"].each do |method|
      ruby_name = (method["name"] == "displayRich") ? "display_rich" : method["name"]
      err = Hron::HronError.eval("test message")
      assert_respond_to err, ruby_name, "HronError missing method: #{ruby_name}"
    end
  end
end
