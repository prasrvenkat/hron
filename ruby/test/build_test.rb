# frozen_string_literal: true

require_relative "test_helper"

# spec/build.json, run as spec/README.md, "Writing a runner" says.
class BuildConformanceTest < Minitest::Test
  BUILD = JSON.parse(File.read(File.expand_path("../../spec/build.json", __dir__)))
  GROUPS = %w[rules order canonical].freeze

  MONTHS = %w[january february march april may june july august september october november december]
    .zip(Hron::MonthName::ALL).to_h.freeze
  WEEKDAYS = Hron::Weekday::ALL.to_h { |day| [day.to_s, day] }.freeze
  ORDINALS = Hron::OrdinalPosition::ALL.to_h { |ordinal| [ordinal.to_s, ordinal] }.freeze
  UNITS = {"minutes" => Hron::IntervalUnit::MIN, "hours" => Hron::IntervalUnit::HOURS}.freeze
  DIRECTIONS = {nil => nil, "next" => Hron::NearestDirection::NEXT, "previous" => Hron::NearestDirection::PREVIOUS}.freeze

  def test_build_json_has_no_group_this_runner_skips
    assert_empty BUILD.keys - ["description"] - GROUPS
    GROUPS.each { |group| assert_empty BUILD.fetch(group).keys - %w[description tests], group }
  end

  GROUPS.each do |group|
    BUILD.fetch(group).fetch("tests").each do |tc|
      name = "test_build_#{group}_#{tc.fetch("name")}"
      raise ArgumentError, "duplicate build case: #{name}" if method_defined?(name)

      define_method(name) do
        assert_empty tc.keys - %w[name description parts error canonical], "case fields this runner does not check"
        data = parts(tc.fetch("parts"))
        if tc.key?("error")
          expected = tc["error"]
          assert_empty expected.keys - %w[kind message], "error fields this runner does not check"
          assert_equal "eval", expected.fetch("kind")
          error = assert_raises(Hron::HronError) { Hron::Schedule.new(data) }
          assert_equal :eval, error.kind
          assert_equal expected.fetch("message"), error.message
          assert_nil error.span
          assert_nil error.input
          assert_nil error.suggestion
          assert_equal "error: #{expected["message"]}", error.display_rich
        else
          canonical = tc.fetch("canonical")
          schedule = Hron::Schedule.new(data)
          assert_equal canonical, schedule.to_s
          assert_equal Hron::Schedule.parse(canonical), schedule
        end
      end
    end
  end

  private

  def fields(object, known)
    assert_kind_of Hash, object
    assert_empty object.keys - known, "fields this runner does not read"
    object
  end

  def only_key(object)
    assert_equal 1, fields(object, object.keys).size, object.inspect
    object.first
  end

  def parts(json)
    fields(json, %w[expression except until starting during timezone])
    Hron::ScheduleData.new(
      expression: expression(json.fetch("expression")),
      timezone: json["timezone"],
      except: json.fetch("except", []).map { |date| dated(date, Hron::NamedException, Hron::IsoException) },
      until: json.key?("until") ? dated(json["until"], Hron::NamedUntil, Hron::IsoUntil) : nil,
      starting: json["starting"],
      during: json.fetch("during", []).map { |month| MONTHS.fetch(month) }
    )
  end

  def expression(json)
    kind, f = only_key(json)
    case kind
    when "interval_repeat"
      fields(f, %w[interval unit from to day_filter])
      day_filter = f.key?("day_filter") ? day_filter(f["day_filter"]) : nil
      Hron::IntervalRepeat.new(f.fetch("interval"), UNITS.fetch(f.fetch("unit")), time_of_day(f.fetch("from")), time_of_day(f.fetch("to")), day_filter)
    when "day_repeat"
      fields(f, %w[interval days times])
      Hron::DayRepeat.new(f.fetch("interval"), day_filter(f.fetch("days")), time_list(f))
    when "week_repeat"
      fields(f, %w[interval days times])
      Hron::WeekRepeat.new(f.fetch("interval"), f.fetch("days").map { |day| WEEKDAYS.fetch(day) }, time_list(f))
    when "month_repeat"
      fields(f, %w[interval target times])
      Hron::MonthRepeat.new(f.fetch("interval"), month_target(f.fetch("target")), time_list(f))
    when "single_date"
      fields(f, %w[date times])
      Hron::SingleDateExpr.new(dated(f.fetch("date"), Hron::NamedDate, Hron::IsoDate), time_list(f))
    when "year_repeat"
      fields(f, %w[interval target times])
      Hron::YearRepeat.new(f.fetch("interval"), year_target(f.fetch("target")), time_list(f))
    else
      flunk "unknown expression #{kind}"
    end
  end

  def time_of_day(text)
    hour, minute = text.split(":").map { |part| Integer(part, 10) }
    Hron::TimeOfDay.new(hour, minute)
  end

  def time_list(f)
    f.fetch("times").map { |text| time_of_day(text) }
  end

  def day_filter(json)
    case json
    when "every" then Hron::DayFilterEvery.new
    when "weekday" then Hron::DayFilterWeekday.new
    when "weekend" then Hron::DayFilterWeekend.new
    else Hron::DayFilterDays.new(fields(json, ["days"]).fetch("days").map { |day| WEEKDAYS.fetch(day) })
    end
  end

  def dated(json, named, iso)
    kind, f = only_key(json)
    case kind
    when "named" then named.new(MONTHS.fetch(fields(f, %w[month day]).fetch("month")), f.fetch("day"))
    when "iso" then iso.new(f)
    else flunk "unknown date #{kind}"
    end
  end

  def month_target(json)
    return Hron::LastDayTarget.new if json == "last_day"
    return Hron::LastWeekdayTarget.new if json == "last_weekday"

    kind, f = only_key(json)
    case kind
    when "days" then Hron::DaysTarget.new(f.map { |spec| day_spec(spec) })
    when "nearest_weekday"
      fields(f, %w[day direction])
      Hron::NearestWeekdayTarget.new(f.fetch("day"), DIRECTIONS.fetch(f.fetch("direction")))
    when "ordinal_weekday"
      fields(f, %w[ordinal weekday])
      Hron::OrdinalWeekdayTarget.new(ORDINALS.fetch(f.fetch("ordinal")), WEEKDAYS.fetch(f.fetch("weekday")))
    else
      flunk "unknown month target #{kind}"
    end
  end

  def day_spec(json)
    kind, value = only_key(json)
    case kind
    when "single" then Hron::SingleDay.new(value)
    when "range" then Hron::DayRange.new(*value)
    else flunk "unknown day spec #{kind}"
    end
  end

  def year_target(json)
    kind, f = only_key(json)
    case kind
    when "date"
      fields(f, %w[month day])
      Hron::YearDateTarget.new(MONTHS.fetch(f.fetch("month")), f.fetch("day"))
    when "ordinal_weekday"
      fields(f, %w[ordinal weekday month])
      Hron::YearOrdinalWeekdayTarget.new(ORDINALS.fetch(f.fetch("ordinal")), WEEKDAYS.fetch(f.fetch("weekday")), MONTHS.fetch(f.fetch("month")))
    when "day_of_month"
      fields(f, %w[day month])
      Hron::YearDayOfMonthTarget.new(f.fetch("day"), MONTHS.fetch(f.fetch("month")))
    when "last_weekday"
      Hron::YearLastWeekdayTarget.new(MONTHS.fetch(fields(f, ["month"]).fetch("month")))
    else
      flunk "unknown year target #{kind}"
    end
  end
end
