# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hron"
require "minitest/autorun"
require "json"
require "time"
require "tzinfo"

module TestHelper
  def self.parse_zoned(s)
    match = s.match(/^(.+)\[(.+)\]$/)
    raise "expected format 'ISO[TZ]', got: #{s}" unless match

    iso_part = match[1]
    tz_name = match[2]

    time = Time.parse(iso_part)

    tz = TZInfo::Timezone.get(tz_name)
    tz.utc_to_local(time.utc)
  rescue TZInfo::InvalidTimezoneIdentifier => e
    raise "invalid timezone: #{tz_name} - #{e.message}"
  end

  # Written in the time's own zone, so a result in the wrong zone fails (spec/README.md,
  # "Writing a runner").
  def self.format_zoned(time)
    zone = time.zone
    name = zone.respond_to?(:identifier) ? zone.identifier : zone
    offset = (time.utc_offset % 60).zero? ? "%:z" : "%::z"
    "#{time.strftime("%Y-%m-%dT%H:%M:%S#{offset}")}[#{name}]"
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
