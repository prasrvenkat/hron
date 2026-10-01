# frozen_string_literal: true

require_relative "test_helper"

class ErrorFuzzTest < Minitest::Test
  INPUTS = 6000
  SEED = 0x5EED_4A0E

  WHAT = [
    "'every' or 'on'",
    "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
    "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')",
    "'at'", "a time (HH:MM)", "'from'", "'to'",
    "'day', 'weekday', 'weekend' or a day name",
    "'on'", "a day name", "'the'",
    "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
    "'day', 'weekday' or a day name",
    "'nearest'", "'weekday'", "a day such as 15th",
    "a month name or 'the'",
    "a day such as 15th, 'last' or an ordinal such as 'first'",
    "'weekday' or a day name",
    "'of'", "a month name", "a day number",
    "a date (YYYY-MM-DD, or a month and day)", "a date (YYYY-MM-DD)", "a timezone"
  ].map { |what| Regexp.escape(what) }.join("|")
  MONTH = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
  DAY = "[0-9]+(?i:st|nd|rd|th)?"
  TIME = "[0-9]{1,2}:[0-9]{2}"

  CLAUSE_ORDER = %w[except until starting during in].freeze
  TOKEN_SEPARATORS = /[ \t\r\n]/
  MAX_NUMBER = 2_147_483_647

  Failure = Struct.new(:input, :span, :spanned)
  Template = Struct.new(:kind, :regex, :check)

  def self.value(text)
    text[/\A[0-9]*/].to_i
  end

  def self.minutes(time)
    hour, minute = time.split(":")
    (value(hour) * 60) + value(minute)
  end

  def self.month_length(month)
    return 29 if month == "feb"

    %w[apr jun sep nov].include?(month) ? 30 : 31
  end

  def self.calendar_date?(text)
    year, month, day = text.split("-").map(&:to_i)
    year >= 1 && Date.valid_date?(year, month, day, Date::GREGORIAN)
  end

  NO_CHECK = ->(_, _) {}

  # From spec/README.md, "Lex errors" and "Parse errors". A `span` group must equal the spanned
  # text; every other group is read by its template's check, which returns a problem or nil.
  TEMPLATES = [
    Template.new(:lex, /\Aunexpected character '(?<span>[!-&(-~])'\z/, lambda do |_, f|
      "'#{f.spanned}' starts a token, so it is never unexpected" if f.spanned.match?(/\A[A-Za-z0-9,]\z/)
    end),
    Template.new(:lex, /\Aunexpected character U\+(?<code>[0-9A-F]{4,})\z/, lambda do |m, f|
      shown = m[:code].to_i(16)
      quotable = shown.between?(0x21, 0x7E) && shown != 0x27
      "U+#{m[:code]} does not describe '#{f.spanned}'" unless f.spanned.length == 1 && f.spanned.ord == shown && !quotable
    end),
    Template.new(:lex, /\Aunknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'\z/, NO_CHECK),
    Template.new(:lex, /\Atime must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))\z/, lambda do |m, _|
      "#{m[:hour]}:#{m[:minute]} is H:MM or HH:MM" if m[:hour].length.between?(1, 2) && m[:minute].length == 2
    end),
    Template.new(:lex, /\Atime must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))\z/, lambda do |m, _|
      "#{m[:hour]}:#{m[:minute]} is in range" unless value(m[:hour]) > 23 || value(m[:minute]) > 59
    end),
    Template.new(:lex, /\Anumber must be at most 2147483647\z/, lambda do |_, f|
      "'#{f.spanned}' is not digits above 2147483647" unless f.spanned.match?(/\A[0-9]+\z/) && value(f.spanned) > MAX_NUMBER
    end),
    Template.new(:parse, /\Aempty expression\z/, lambda do |_, f|
      blank = f.input.delete(" \t\r\n").empty?
      "empty expression with span #{f.span} for #{f.input.inspect}" unless blank && f.span == [0, 0]
    end),
    Template.new(:parse, /\Aexpected (?:#{WHAT}), got (?:'(?<span>.+)'|(?<end>end of input))\z/, lambda do |m, f|
      next unless m[:end]

      stop = f.input.sub(/[ \t\r\n]+\z/, "").length
      "end of input at #{f.span}, expected #{stop}..#{stop}" unless f.span == [stop, stop]
    end),
    Template.new(:parse, /\Ainterval must be 1-2147483647, got (?<span>[0-9]+)\z/, lambda do |_, f|
      "interval #{f.spanned} is valid" unless value(f.spanned).zero?
    end),
    Template.new(:parse, /\Aday must be 1-31, got (?<span>#{DAY})\z/, lambda do |_, f|
      day = value(f.spanned)
      "day #{day} is within 1-31" if day.between?(1, 31)
    end),
    Template.new(:parse, /\Aday must be 1-(?<max>[0-9]+) for (?<month>#{MONTH}), got (?<span>#{DAY})\z/, lambda do |m, f|
      max = value(m[:max])
      day = value(f.spanned)
      "day #{day} against 1-#{max} for #{m[:month]}" unless max == month_length(m[:month]) && day > max && day <= 31
    end),
    Template.new(:parse, /\Aday range must not run backwards: (?<a>#{DAY}) to (?<b>#{DAY})\z/, lambda do |m, f|
      spans_both = f.spanned.start_with?(m[:a]) && f.spanned.end_with?(m[:b])
      "#{m[:a]} to #{m[:b]} against the span '#{f.spanned}'" unless spans_both && value(m[:a]) > value(m[:b])
    end),
    Template.new(:parse, /\Atime window must not run backwards: (?<from>#{TIME}) to (?<to>#{TIME}) \(a window cannot cross midnight\)\z/, lambda do |m, f|
      spans_both = f.spanned.start_with?(m[:from]) && f.spanned.end_with?(m[:to])
      "#{m[:from]} to #{m[:to]} against the span '#{f.spanned}'" unless spans_both && minutes(m[:from]) > minutes(m[:to])
    end),
    Template.new(:parse, /\Adate must be a calendar date from 0001-01-01 to 9999-12-31, got (?<span>[0-9]{4}-[0-9]{2}-[0-9]{2})\z/, lambda do |_, f|
      "#{f.spanned} is a calendar date" if calendar_date?(f.spanned)
    end),
    Template.new(:parse, /\Atimezone must be UTC or an Area\/Location name such as America\/New_York, got (?<span>.+)\z/, NO_CHECK),
    Template.new(:parse, /\Aduplicate '(?<keyword>except|until|starting|during|in)' clause\z/, lambda do |m, f|
      "duplicate '#{m[:keyword]}' but the span holds '#{f.spanned}'" unless m[:keyword] == f.spanned.downcase(:ascii)
    end),
    Template.new(:parse, /\A'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'\z/, lambda do |m, f|
      keyword_at = CLAUSE_ORDER.index(m[:keyword])
      last_at = CLAUSE_ORDER.index(m[:last])
      earlier = keyword_at && last_at && keyword_at < last_at
      "'#{m[:keyword]}' before '#{m[:last]}' with the span '#{f.spanned}'" unless earlier && m[:keyword] == f.spanned.downcase(:ascii)
    end),
    Template.new(:parse, /\Aunexpected '(?<span>.+)' after the schedule\z/, NO_CHECK),
    Template.new(:parse, /\Auntil (?<month>#{MONTH}) (?<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date\z/, lambda do |m, f|
      words = f.spanned.split(TOKEN_SEPARATORS).reject(&:empty?)
      until_word, month, day = words
      matches_message = words.length == 3 && !f.spanned.match?(/[ \t\r\n]\z/) &&
        until_word.casecmp?("until") && month.downcase(:ascii).start_with?(m[:month]) &&
        day.match?(/\A[0-9]/) && value(day).to_s == m[:day]
      "the span '#{f.spanned}' is not 'until #{m[:month]} #{m[:day]}'" unless matches_message
    end)
  ].freeze

  FRAGMENTS = [
    "every", "on", "at", "from", "to", "in", "IN", "of", "the", "last", "except", "until",
    "starting", "during", "nearest", "next", "previous", "day", "Days", "weekdays", "weekend",
    "week", "month", "years", "min", "hrs", "monday", "FRI", "jan", "february", "first", "fifth",
    "0", "1", "00", "15th", "31ST", "2nd", "2147483647", "2147483648", "99999999999999999999",
    "09:00", "9:5", "24:00", "9:", "17:30", "2026-02-28", "2026-02-30", "0000-01-01", "12026-03-15",
    ",", ":", "-", "/", "'", "\"", "#", "~", "_", "UTC", "America/New_York", "Nope/Zone",
    "Europe/\u0130stanbul", "\u00e9", "e\u0301", "\u212a", "\u00a0", "\u2028", "\ufeff", "\uff10",
    "\u{1f600}", "\u{10ffff}", "\u{1d7d8}", "\0", "\v", "\f", "\u007f", "\e"
  ].freeze
  SEPARATORS = ["", " ", " ", " ", "  ", "\t", "\r\n", "\n"].freeze

  CLAUSES = [
    "except dec 25", "except 2026-12-25, jan 1", "until 2027-12-31", "until dec 31",
    "starting 2026-01-01", "during jan, jul", "in UTC", "IN America/New_York"
  ].freeze

  MASK = 0xFFFF_FFFF_FFFF_FFFF

  # SplitMix64: a fixed seed gives the same inputs on every run.
  class Rng
    def initialize(seed)
      @state = seed
    end

    def next_u64
      @state = (@state + 0x9E37_79B9_7F4A_7C15) & MASK
      z = @state
      z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK
      z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & MASK
      z ^ (z >> 31)
    end

    def below(n)
      next_u64 % n
    end

    def pick(items)
      items[below(items.length)]
    end
  end

  def corpus
    spec = TestHelper.load_spec
    parse_inputs = spec["parse"].values.filter_map { |section| section["tests"] if section.is_a?(Hash) }.flatten
    (parse_inputs + spec["parse_errors"]["tests"]).map { |tc| tc["input"] }
  end

  def random_text(rng)
    (0..rng.below(12)).map { rng.pick(SEPARATORS) + rng.pick(FRAGMENTS) }.join
  end

  def mutate(rng, input)
    # Unlike `split(" ")`, this keeps empty words, as splitting on one space should.
    words = input.split(/ /, -1)
    words = [""] if words.empty?
    i = rng.below(words.length)
    case rng.below(7)
    when 0 then words.delete_at(i)
    when 1
      j = rng.below(words.length)
      words[i], words[j] = words[j], words[i]
    when 2 then words.insert(rng.below(words.length + 1), words[i])
    when 3 then return input[0, rng.below(input.length + 1)]
    when 4 then words[i] = words[i].upcase(:ascii)
    when 5 then words[i] = rng.pick(FRAGMENTS)
    else
      fragment = rng.pick(FRAGMENTS)
      chars = words[i].chars
      chars.insert(rng.below(chars.length + 1), *fragment.chars)
      words[i] = chars.join
    end
    words.join(" ")
  end

  def with_clauses(rng, input)
    (0..rng.below(4)).reduce(input) { |out, _| "#{out} #{rng.pick(CLAUSES)}" }
  end

  def generate(rng, corpus)
    case rng.below(4)
    when 0 then random_text(rng)
    when 1 then with_clauses(rng, corpus[rng.below(corpus.length)])
    else
      input = corpus[rng.below(corpus.length)]
      rng.below(4).times { input = mutate(rng, input) }
      input
    end
  end

  def check(input, error)
    return "neither lex nor parse: #{error.kind} #{error.message}" unless %i[lex parse].include?(error.kind)
    return "validate is true" if Hron::Schedule.validate(input)
    return "error input is #{error.input.inspect}" unless error.input == input

    span = [error.span.start, error.span.end_pos]
    return "span #{span} outside 0..#{input.length}" unless span[0] >= 0 && span[1].between?(span[0], input.length)

    failure = Failure.new(input, span, input[span[0]...span[1]])
    index = nil
    match = nil
    TEMPLATES.each_with_index do |template, i|
      next unless template.kind == error.kind

      match = template.regex.match(error.message)
      break index = i if match
    end
    return "#{error.kind} message '#{error.message}' matches no template" unless index

    if match.names.include?("span") && match[:span] && match[:span] != failure.spanned
      return "message echoes '#{match[:span]}' but the span holds '#{failure.spanned}'"
    end

    problem = TEMPLATES[index].check.call(match, failure)
    return problem if problem

    expected_suggestion = "until #{match[:month]} #{match[:day]} starting YYYY-MM-DD" if error.message.start_with?("until ")
    return "suggestion #{error.suggestion.inspect}, expected #{expected_suggestion.inspect}" unless error.suggestion == expected_suggestion

    rich = error.display_rich
    return "display_rich is not three lines: #{rich.inspect}" unless rich.split("\n", -1).length == 3 && rich.start_with?("error: #{error.message}\n")

    index
  end

  def test_generated_inputs_fail_only_with_spec_errors
    corpus = self.corpus
    rng = Rng.new(SEED)
    hits = Array.new(TEMPLATES.length, 0)
    parsed = 0
    failures = []

    INPUTS.times do
      input = generate(rng, corpus)
      begin
        Hron::Schedule.parse(input)
        parsed += 1
      rescue Hron::HronError => e
        outcome = check(input, e)
        outcome.is_a?(Integer) ? hits[outcome] += 1 : failures << "#{input.inspect}: #{outcome}"
      rescue StandardError, SystemStackError => e
        failures << "#{input.inspect}: raised #{e.class}: #{e.message}"
      end
    end

    assert failures.empty?, "#{failures.length} failures, first ones:\n#{failures.first(20).join("\n")}"
    assert_operator parsed, :>, INPUTS / 20, "only #{parsed} inputs parsed; the generator has drifted"
    unused = TEMPLATES.zip(hits).select { |_, count| count.zero? }.map { |template, _| template.regex.source }
    assert unused.empty?, "templates no input produced:\n#{unused.join("\n")}"
  end
end
