# frozen_string_literal: true

require "json"
require "time"
require "tzinfo"
require "hron"

def parse_zoned(s)
  iso, zone = s.match(/\A(.+)\[(.+)\]\z/).captures
  TZInfo::Timezone.get(zone).to_local(Time.iso8601(iso))
end

# Time carries no zone, so only the instant returned is compared, written in the
# schedule's timezone (UTC when none).
def format_zoned(time, zone)
  time && "#{TZInfo::Timezone.get(zone).to_local(time).strftime("%Y-%m-%dT%H:%M:%S%:z")}[#{zone}]"
end

def evaluate(c)
  return Hron::Schedule.from_cron(c["expr"]).to_s if c["op"] == "fromCron"

  schedule = Hron::Schedule.parse(c["expr"])
  zone = schedule.timezone || "UTC"
  format = ->(t) { format_zoned(t, zone) }
  case c["op"]
  when "parse" then schedule.to_s
  when "toCron" then schedule.to_cron
  when "next" then format.call(schedule.next_from(parse_zoned(c["now"])))
  when "nextN" then schedule.next_n_from(parse_zoned(c["now"]), c["n"]).map(&format)
  when "prev" then format.call(schedule.previous_from(parse_zoned(c["now"])))
  when "matches" then schedule.matches(parse_zoned(c["datetime"]))
  when "between" then schedule.between(parse_zoned(c["from"]), parse_zoned(c["to"])).map(&format).to_a
  when "occurrences" then schedule.occurrences(parse_zoned(c["from"])).first(c["n"]).map(&format)
  else raise ArgumentError, "unknown op #{c["op"]}"
  end
end

def details(e)
  span = e.span && [e.span.start, e.span.end_pos]
  {kind: e.kind, message: e.message, span: span, suggestion: e.suggestion}
end

def run(c)
  {ok: true, result: evaluate(c)}
rescue Hron::HronError => e
  {ok: false, error: details(e)}
rescue StandardError, SystemStackError => e
  {ok: false, error: {kind: "crash", message: "#{e.class}: #{e.message}"}}
end

$stdout.sync = true
$stdin.each_line do |line|
  c = JSON.parse(line)
  puts JSON.generate({id: c["id"], **run(c)})
end
