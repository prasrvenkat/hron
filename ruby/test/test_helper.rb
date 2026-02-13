# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hron"
require "minitest/autorun"
require "json"
require "time"
require "tzinfo"

module TestHelper
  # Parse '2026-02-06T12:00:00+00:00[UTC]' into a timezone-aware Time
  def self.parse_zoned(s)
    match = s.match(/^(.+)\[(.+)\]$/)
    raise "expected format 'ISO[TZ]', got: #{s}" unless match

    iso_part = match[1]
    tz_name = match[2]

    # Parse the ISO timestamp
    time = Time.parse(iso_part)

    # Convert to the named timezone
    tz = TZInfo::Timezone.get(tz_name)
    tz.utc_to_local(time.utc)
  rescue TZInfo::InvalidTimezoneIdentifier => e
    raise "invalid timezone: #{tz_name} - #{e.message}"
  end

  # Format a Time as '2026-02-06T12:00:00+00:00[TZ]'
  def self.format_zoned(time, tz_name = "UTC")
    tz = TZInfo::Timezone.get(tz_name)
    local_time = tz.utc_to_local(time.utc)

    # Get offset for the specific time, not current time
    period = tz.period_for_utc(time.utc)
    offset = period.offset.utc_total_offset
    offset_hours = offset.abs / 3600
    offset_mins = (offset.abs % 3600) / 60
    offset_sign = (offset >= 0) ? "+" : "-"
    offset_str = format("%<sign>s%<hours>02d:%<mins>02d", sign: offset_sign, hours: offset_hours, mins: offset_mins)

    iso = local_time.strftime("%Y-%m-%dT%H:%M:%S") + offset_str
    "#{iso}[#{tz_name}]"
  end

  def self.load_spec
    spec_path = File.expand_path("../../spec/tests.json", __dir__)
    JSON.parse(File.read(spec_path))
  end

  def self.load_api_spec
    spec_path = File.expand_path("../../spec/api.json", __dir__)
    JSON.parse(File.read(spec_path))
  end
end
