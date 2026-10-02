# frozen_string_literal: true

require_relative "test_helper"

class ApiConformanceTest < Minitest::Test
  API_SPEC = TestHelper.load_api_spec

  # spec/api.json, notes.ruby.
  RUBY_NAMES = {
    "parse" => :parse, "fromCron" => :from_cron, "validate" => :validate,
    "nextFrom" => :next_from, "nextNFrom" => :next_n_from, "previousFrom" => :previous_from,
    "matches" => :matches, "occurrences" => :occurrences, "between" => :between,
    "toCron" => :to_cron, "toString" => :to_s, "equals" => :==,
    "timezone" => :timezone, "expression" => :expression, "except" => :except,
    "until" => :until, "starting" => :starting, "during" => :during,
    "kind" => :kind, "message" => :message, "span" => :span, "input" => :input,
    "suggestion" => :suggestion, "displayRich" => :display_rich,
    "lex" => :lex, "eval" => :eval, "cron" => :cron
  }.freeze

  SECTIONS = {
    "schedule" => %w[staticMethods instanceMethods getters],
    "error" => %w[description kinds properties constructors methods]
  }.freeze

  # Each section's members must be public methods defined by Hron itself, not inherited from
  # Object, except an error's properties, of which message comes from Exception.
  LOOKUPS = {
    %w[schedule staticMethods] => ->(name) { Hron::Schedule.method(name) if Hron::Schedule.singleton_class.public_method_defined?(name, false) },
    %w[schedule instanceMethods] => ->(name) { Hron::Schedule.instance_method(name) if Hron::Schedule.public_method_defined?(name, false) },
    %w[schedule getters] => ->(name) { Hron::Schedule.instance_method(name) if Hron::Schedule.public_method_defined?(name, false) },
    %w[error properties] => ->(name) { Hron::HronError.instance_method(name) if Hron::HronError.public_method_defined?(name) },
    %w[error methods] => ->(name) { Hron::HronError.instance_method(name) if Hron::HronError.public_method_defined?(name, false) },
    %w[error constructors] => ->(name) { Hron::HronError.method(name) if Hron::HronError.singleton_class.public_method_defined?(name, false) }
  }.freeze

  def self.problems(spec, names = RUBY_NAMES)
    found = []
    LOOKUPS.each do |path, lookup|
      spec.dig(*path).each do |member|
        name = member.is_a?(Hash) ? member.fetch("name") : member
        ruby_name = names[name]
        next found << "#{path.last} #{name}: no Ruby name" unless ruby_name

        method = lookup.call(ruby_name)
        next found << "#{path.last} #{name}: no public #{ruby_name}" unless method
        next unless member.is_a?(Hash)

        arity = member.fetch("params", []).length
        found << "#{path.last} #{name}: #{ruby_name} takes #{method.arity} arguments, not #{arity}" unless method.arity == arity
      end
    end
    kinds = Hron::ErrorKind.constants.map { |constant| Hron::ErrorKind.const_get(constant) }
    spec_kinds = spec.dig("error", "kinds").map(&:to_sym)
    (spec_kinds - kinds).each { |kind| found << "kinds #{kind}: not in Hron::ErrorKind" }
    (kinds - spec_kinds).each { |kind| found << "kinds #{kind}: not in api.json" }
    found
  end

  def copy_of_spec
    JSON.parse(JSON.generate(API_SPEC))
  end

  def test_ruby_has_every_member_of_api_json
    assert_empty self.class.problems(API_SPEC)
  end

  def test_api_json_has_no_section_this_test_skips
    SECTIONS.each do |section, keys|
      assert_empty API_SPEC.fetch(section).keys - keys, "unchecked #{section} sections"
    end
  end

  def test_the_check_fails_for_a_member_ruby_lacks
    {
      %w[schedule staticMethods] => {"name" => "fakeStatic", "params" => []},
      %w[schedule instanceMethods] => {"name" => "fakeMethod", "params" => []},
      %w[schedule getters] => {"name" => "fakeGetter"},
      %w[error properties] => {"name" => "fakeProperty"},
      %w[error methods] => {"name" => "fakeErrorMethod", "params" => []},
      %w[error constructors] => "fakeConstructor",
      %w[error kinds] => "fake_kind"
    }.each do |path, member|
      spec = copy_of_spec
      spec.dig(*path) << member
      name = member.is_a?(Hash) ? member["name"] : member
      [RUBY_NAMES, RUBY_NAMES.merge(name => :fake_member)].each do |names|
        assert self.class.problems(spec, names).any? { |problem| problem.include?(name) }, "#{path.join(".")} #{name}"
      end
    end
  end

  def test_the_check_fails_for_a_wrong_arity_or_an_inherited_method
    spec = copy_of_spec
    spec.dig("schedule", "staticMethods").find { |m| m["name"] == "parse" }["params"] << {"name" => "extra"}
    assert_includes self.class.problems(spec), "staticMethods parse: parse takes 1 arguments, not 2"
    assert_includes self.class.problems(API_SPEC, RUBY_NAMES.merge("equals" => :!=)), "instanceMethods equals: no public !="
  end

  def test_the_check_fails_for_an_error_kind_api_json_lacks
    spec = copy_of_spec
    spec.dig("error", "kinds").delete("cron")
    assert_equal ["kinds cron: not in api.json"], self.class.problems(spec).grep(/\Akinds/)
  end

  def test_equality_is_eq_eql_and_hash_of_schedule_itself
    %i[== eql? hash].each do |name|
      assert_equal Hron::Schedule, Hron::Schedule.instance_method(name).owner, name.to_s
    end
  end

  def setup
    @schedule = Hron::Schedule.parse("every day at 09:00")
    @now = Time.utc(2026, 2, 6, 12, 0, 0)
  end

  def test_parse
    assert_instance_of Hron::Schedule, Hron::Schedule.parse("every day at 09:00")
  end

  def test_from_cron
    assert_equal "every day at 09:00", Hron::Schedule.from_cron("0 9 * * *").to_s
  end

  def test_validate
    assert_equal true, Hron::Schedule.validate("every day at 09:00")
    assert_equal false, Hron::Schedule.validate("not a schedule")
  end

  def test_next_from
    assert_equal Time.utc(2026, 2, 7, 9, 0, 0), @schedule.next_from(@now)
  end

  def test_next_n_from
    assert_equal [7, 8, 9], @schedule.next_n_from(@now, 3).map(&:day)
  end

  def test_previous_from
    assert_equal Time.utc(2026, 2, 6, 9, 0, 0), @schedule.previous_from(@now)
  end

  def test_matches
    assert_equal true, @schedule.matches(Time.utc(2026, 2, 6, 9, 0, 0))
    assert_equal false, @schedule.matches(@now)
  end

  def test_to_cron
    assert_equal "0 9 * * *", @schedule.to_cron
  end

  def test_to_string
    assert_equal "every day at 09:00", @schedule.to_s
  end

  def test_timezone_none
    assert_nil @schedule.timezone
  end

  def test_timezone_present
    assert_equal "America/New_York", Hron::Schedule.parse("every day at 09:00 in america/new_york").timezone
  end

  def test_schedules_with_equal_parts_are_equal_with_equal_hashes
    a = Hron::Schedule.parse("every day at 9:00")
    b = Hron::Schedule.parse("every day at 09:00")
    assert_equal a, b
    assert a.eql?(b)
    assert_equal a.hash, b.hash
    assert_equal :found, {a => :found}[b]
  end

  def test_a_schedule_equals_nothing_but_a_schedule
    [nil, "every day at 09:00", @schedule.data, @schedule.expression, 1, Object.new].each do |other|
      assert_equal false, @schedule == other, other.inspect
      assert_equal false, @schedule.eql?(other), other.inspect
    end
  end

  def test_lists_compare_in_order_with_duplicates
    [
      ["every monday, friday at 09:00", "every friday, monday at 09:00"],
      ["every day at 09:00, 17:00", "every day at 17:00, 09:00"],
      ["every day at 09:00 except dec 25", "every day at 09:00 except dec 25, dec 25"],
      ["every day at 09:00 during jan", "every day at 09:00 during jan, jan"]
    ].each do |left, right|
      assert_not_equal_schedules Hron::Schedule.parse(left), Hron::Schedule.parse(right)
    end
  end

  def test_schedules_that_differ_only_in_one_clause_are_not_equal
    plain = Hron::Schedule.parse("every day at 09:00")
    [
      "every day at 09:00 except dec 25",
      "every day at 09:00 until 2027-01-01",
      "every day at 09:00 starting 2026-01-05",
      "every day at 09:00 during jan",
      "every day at 09:00 in UTC"
    ].each do |clause|
      assert_not_equal_schedules plain, Hron::Schedule.parse(clause)
    end
  end

  def assert_not_equal_schedules(left, right)
    refute_equal left, right, "#{left} == #{right}"
    refute left.eql?(right), "#{left}.eql?(#{right})"
  end

  def test_a_from_cron_schedule_equals_the_parse_of_its_to_s
    from_cron = Hron::Schedule.from_cron("*/30 9-17 * 1-6 1-5")
    parsed = Hron::Schedule.parse(from_cron.to_s)
    assert_equal parsed, from_cron
    assert_equal parsed.hash, from_cron.hash
  end

  # spec/README.md, "Timestamps and counts": a usage error, never a HronError or false.
  def test_an_input_that_is_not_a_string_is_a_type_error
    [nil, 123, :every, ["every day at 09:00"], Object.new].each do |input|
      [
        [Hron::Schedule, :parse, "input"], [Hron::Schedule, :validate, "input"], [Hron::Schedule, :from_cron, "cron_expr"],
        [Hron, :parse_schedule, "input"], [Hron, :validate, "input"], [Hron, :from_cron, "cron_expr"]
      ].each do |receiver, method, param|
        error = assert_raises(TypeError, "#{receiver}.#{method}(#{input.inspect})") { receiver.public_send(method, input) }
        assert_equal "#{param} must be a String, not #{input.class}", error.message
      end
    end
  end

  def test_a_string_subclass_is_a_string
    text = Class.new(String)
    assert_equal @schedule, Hron::Schedule.parse(text.new("every day at 09:00"))
    assert_equal true, Hron::Schedule.validate(text.new("every day at 09:00"))
    assert_equal @schedule, Hron::Schedule.from_cron(text.new("0 9 * * *"))
  end
end
