import Foundation
import Hron
import Testing

/// Generated inputs never crash `parse`, and every one it rejects fails with an error the spec
/// describes, its span within the input in code points.
@Suite struct ErrorFuzzTests {
  static let inputs = 6000
  static let seed: UInt64 = 0x5EED_4A0E

  @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
  @Test func generatedInputsFailOnlyWithSpecErrors() throws {
    let templates = try Template.all()
    let corpus = Self.corpus()
    var random = SplitMix64(state: Self.seed)
    var hits = [Int](repeating: 0, count: templates.count)
    var parsed = 0
    var failures: [String] = []

    for _ in 0..<Self.inputs {
      let input = generate(&random, corpus)
      do {
        _ = try Schedule.parse(input)
        parsed += 1
      } catch {
        switch check(input, error, templates) {
        case .success(let index): hits[index] += 1
        case .failure(let problem): failures.append("\(input.debugDescription): \(problem.text)")
        }
      }
    }

    #expect(
      failures.isEmpty,
      "\(failures.count) failures, first ones:\n\(failures.prefix(20).joined(separator: "\n"))")
    #expect(parsed > Self.inputs / 20, "only \(parsed) inputs parsed; the generator has drifted")
    let unused = zip(templates, hits).filter { $0.1 == 0 }.map(\.0.pattern)
    #expect(unused.isEmpty, "templates no input produced: \(unused)")
  }

  @available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
  @Test func aSpanOutsideTheInputFails() throws {
    let error = HronError.lex(
      "unexpected character '#'", span: HronError.Span(start: 5, end: 6), input: "ab#")
    guard case .failure(let problem) = check("ab#", error, try Template.all()) else {
      Issue.record("a span past the end of the input was accepted")
      return
    }
    #expect(problem.text.contains("outside"))
  }

  static func corpus() -> [String] {
    let parse = Spec.cases(in: "parse").map { $0.string("input") }
    return parse + Spec.flatCases(in: "parse_errors").map { $0.string("input") }
  }
}

struct Problem: Error {
  let text: String
}

/// SplitMix64: a fixed seed gives the same inputs on every platform.
struct SplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func below(_ n: Int) -> Int {
    Int(next() % UInt64(n))
  }

  mutating func pick<T>(_ items: [T]) -> T {
    items[below(items.count)]
  }
}

private let fragments = [
  "every", "on", "at", "from", "to", "in", "IN", "of", "the", "last", "except", "until",
  "starting", "during", "nearest", "next", "previous", "day", "Days", "weekdays", "weekend",
  "week", "month", "years", "min", "hrs", "monday", "FRI", "jan", "february", "first", "fifth",
  "0", "1", "00", "15th", "31ST", "2nd", "2147483647", "2147483648", "99999999999999999999",
  "09:00", "9:5", "24:00", "9:", "17:30", "2026-02-28", "2026-02-30", "0000-01-01",
  "12026-03-15", ",", ":", "-", "/", "'", "\"", "#", "~", "_", "UTC", "America/New_York",
  "Nope/Zone", "Europe/\u{130}stanbul", "\u{e9}", "e\u{301}", "\u{212a}", "\u{a0}", "\u{2028}",
  "\u{feff}", "\u{ff10}", "\u{1f600}", "\u{10ffff}", "\u{1d7d8}", "\0", "\u{b}", "\u{c}",
  "\u{7f}", "\u{1b}",
]
private let separators = ["", " ", " ", " ", "  ", "\t", "\r\n", "\n"]
private let clauses = [
  "except dec 25", "except 2026-12-25, jan 1", "until 2027-12-31", "until dec 31",
  "starting 2026-01-01", "during jan, jul", "in UTC", "IN America/New_York",
]

private func generate(_ random: inout SplitMix64, _ corpus: [String]) -> String {
  switch random.below(4) {
  case 0:
    return (0...random.below(12)).map { _ in random.pick(separators) + random.pick(fragments) }
      .joined()
  case 1:
    var input = random.pick(corpus)
    for _ in 0...random.below(4) {
      input += " " + random.pick(clauses)
    }
    return input
  default:
    var input = random.pick(corpus)
    for _ in 0..<random.below(4) {
      input = mutate(&random, input)
    }
    return input
  }
}

/// Edits by Unicode scalars, as the spec counts code points.
private func mutate(_ random: inout SplitMix64, _ input: String) -> String {
  var words = input.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false)
    .map { Array($0) }
  let i = random.below(words.count)
  switch random.below(7) {
  case 0:
    words.remove(at: i)
  case 1:
    words.swapAt(i, random.below(words.count))
  case 2:
    words.insert(words[i], at: random.below(words.count + 1))
  case 3:
    let scalars = Array(input.unicodeScalars)
    return string(scalars[..<random.below(scalars.count + 1)])
  case 4:
    words[i] = Array(string(words[i]).uppercased().unicodeScalars)
  case 5:
    words[i] = Array(random.pick(fragments).unicodeScalars)
  default:
    let fragment = random.pick(fragments)
    words[i].insert(contentsOf: fragment.unicodeScalars, at: random.below(words[i].count + 1))
  }
  return words.map(string).joined(separator: " ")
}

private func string<S: Sequence<Unicode.Scalar>>(_ scalars: S) -> String {
  var text = String.UnicodeScalarView()
  text.append(contentsOf: scalars)
  return String(text)
}

struct Failure {
  let input: String
  let span: HronError.Span
  let spanned: String
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
private func check(_ input: String, _ error: HronError, _ templates: [Template]) -> Result<
  Int, Problem
> {
  let kind: String
  switch error.kind {
  case .lex: kind = "lex"
  case .parse: kind = "parse"
  case .eval, .cron: return .failure(Problem(text: "neither lex nor parse: \(error)"))
  }
  guard !Schedule.validate(input) else { return .failure(Problem(text: "validate is true")) }
  guard error.input == input else {
    return .failure(Problem(text: "error input is \(String(describing: error.input))"))
  }
  let scalars = Array(input.unicodeScalars)
  guard let span = error.span, 0 <= span.start, span.start <= span.end, span.end <= scalars.count
  else {
    return .failure(
      Problem(text: "span \(String(describing: error.span)) outside 0...\(scalars.count)"))
  }
  let failure = Failure(input: input, span: span, spanned: string(scalars[span.start..<span.end]))
  for (index, template) in templates.enumerated() where template.kind == kind {
    guard let match = try? template.regex.wholeMatch(in: error.message) else { continue }
    let groups = Groups(match: match)
    if let echoed = groups["span"], echoed != failure.spanned {
      return .failure(
        Problem(text: "message echoes '\(echoed)' but the span holds '\(failure.spanned)'"))
    }
    if let problem = template.check(groups, failure) {
      return .failure(Problem(text: problem))
    }
    let expectedSuggestion =
      error.message.hasPrefix("until ")
      ? "until \(groups["month"] ?? "") \(groups["day"] ?? "") starting YYYY-MM-DD" : nil
    guard error.suggestion == expectedSuggestion else {
      return .failure(
        Problem(
          text:
            "suggestion \(String(describing: error.suggestion)), expected \(String(describing: expectedSuggestion))"
        ))
    }
    let rich = error.displayRich()
    guard rich.split(separator: "\n", omittingEmptySubsequences: false).count == 3,
      rich.hasPrefix("error: \(error.message)\n")
    else {
      return .failure(Problem(text: "displayRich is not three lines: \(rich.debugDescription)"))
    }
    return .success(index)
  }
  return .failure(Problem(text: "\(kind) message '\(error.message)' matches no template"))
}

@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
struct Groups {
  let match: Regex<AnyRegexOutput>.Match

  subscript(name: String) -> String? {
    match.output[name]?.substring.map(String.init)
  }
}

/// A message from spec/README.md, "Lex errors" and "Parse errors". A `span` group must equal
/// the spanned text; the check reads every other group.
@available(macOS 13, iOS 16, tvOS 16, watchOS 9, *)
struct Template {
  let kind: String
  let pattern: String
  let regex: Regex<AnyRegexOutput>
  let check: (Groups, Failure) -> String?

  init(
    _ kind: String, _ pattern: String,
    check: @escaping (Groups, Failure) -> String? = { _, _ in nil }
  ) throws {
    self.kind = kind
    self.pattern = pattern
    regex = try Regex(pattern)
    self.check = check
  }

  static let what = [
    "'every' or 'on'",
    "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
    #"a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)"#,
    "'at'", #"a time \(HH:MM\)"#, "'from'", "'to'",
    "'day', 'weekday', 'weekend' or a day name",
    "'on'", "a day name", "'the'",
    "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
    "'day', 'weekday' or a day name",
    "'nearest'", "'weekday'", "a day such as 15th",
    "a month name or 'the'",
    "a day such as 15th, 'last' or an ordinal such as 'first'",
    "'weekday' or a day name",
    "'of'", "a month name", "a day number",
    #"a date \(YYYY-MM-DD, or a month and day\)"#, #"a date \(YYYY-MM-DD\)"#, "a timezone",
  ].joined(separator: "|")
  static let month = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
  static let day = "[0-9]+(?i:st|nd|rd|th)?"
  static let time = "[0-9]{1,2}:[0-9]{2}"
  static let clauseOrder = ["except", "until", "starting", "during", "in"]

  static func all() throws -> [Template] {
    [
      try Template("lex", #"unexpected character '(?<span>[!-&(-~])'"#) { _, failure in
        let scalar = failure.spanned.unicodeScalars.first ?? " "
        let startsAToken =
          ("a"..."z").contains(scalar)
          || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == ","
        return startsAToken ? "'\(scalar)' starts a token, so it is never unexpected" : nil
      },
      try Template("lex", #"unexpected character U\+(?<code>[0-9A-F]{4,})"#) { groups, failure in
        let shown = UInt32(groups["code"] ?? "", radix: 16)
        let quotable = shown.map { (0x21...0x7e).contains($0) && $0 != 0x27 } ?? true
        let scalars = Array(failure.spanned.unicodeScalars)
        return scalars.count == 1 && scalars[0].value == shown && !quotable
          ? nil : "U+\(groups["code"] ?? "") does not describe '\(failure.spanned)'"
      },
      try Template("lex", #"unknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'"#),
      try Template(
        "lex", #"time must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))"#
      ) { groups, _ in
        let (hour, minute) = (groups["hour"] ?? "", groups["minute"] ?? "")
        return !(1...2).contains(hour.count) || minute.count != 2
          ? nil : "\(hour):\(minute) is H:MM or HH:MM"
      },
      try Template(
        "lex",
        #"time must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))"#
      ) { groups, _ in
        let (hour, minute) = (value(groups["hour"]), value(groups["minute"]))
        return hour > 23 || minute > 59 ? nil : "\(hour):\(minute) is in range"
      },
      try Template("lex", "number must be at most 2147483647") { _, failure in
        let digits =
          !failure.spanned.isEmpty && failure.spanned.allSatisfy(\.isASCII)
          && failure.spanned.allSatisfy(\.isNumber)
        return digits && value(failure.spanned) > 2_147_483_647
          ? nil : "'\(failure.spanned)' is not digits above 2147483647"
      },
      try Template("parse", "empty expression") { _, failure in
        let blank = failure.input.unicodeScalars.allSatisfy {
          " \t\r\n".unicodeScalars.contains($0)
        }
        return blank && failure.span == HronError.Span(start: 0, end: 0)
          ? nil : "empty expression with span \(failure.span)"
      },
      try Template("parse", "expected (?:\(what)), got (?:'(?<span>.+)'|(?<end>end of input))") {
        groups, failure in
        guard groups["end"] != nil else { return nil }
        let scalars = Array(failure.input.unicodeScalars)
        let end = (scalars.lastIndex { !" \t\r\n".unicodeScalars.contains($0) } ?? -1) + 1
        return failure.span == HronError.Span(start: end, end: end)
          ? nil : "end of input at \(failure.span), expected \(end)..<\(end)"
      },
      try Template("parse", "interval must be 1-2147483647, got (?<span>[0-9]+)") { _, failure in
        value(failure.spanned) == 0 ? nil : "interval \(failure.spanned) is valid"
      },
      try Template("parse", "day must be 1-31, got (?<span>\(day))") { _, failure in
        let day = value(failure.spanned)
        return day == 0 || day > 31 ? nil : "day \(day) is within 1-31"
      },
      try Template(
        "parse", "day must be 1-(?<max>[0-9]+) for (?<month>\(month)), got (?<span>\(day))"
      ) { groups, failure in
        let month = groups["month"] ?? ""
        let length = month == "feb" ? 29 : ["apr", "jun", "sep", "nov"].contains(month) ? 30 : 31
        let (max, day) = (value(groups["max"]), value(failure.spanned))
        return max == length && day > max && day <= 31
          ? nil : "day \(day) against 1-\(max) for \(month)"
      },
      try Template("parse", "day range must not run backwards: (?<a>\(day)) to (?<b>\(day))") {
        groups, failure in
        let (a, b) = (groups["a"] ?? "", groups["b"] ?? "")
        let spansBoth = failure.spanned.hasPrefix(a) && failure.spanned.hasSuffix(b)
        return spansBoth && value(a) > value(b) ? nil : "\(a) to \(b) against '\(failure.spanned)'"
      },
      try Template(
        "parse",
        #"time window must not run backwards: (?<from>\#(time)) to (?<to>\#(time)) \(a window cannot cross midnight\)"#
      ) { groups, failure in
        let (from, to) = (groups["from"] ?? "", groups["to"] ?? "")
        let minutes = { (time: String) in
          let parts = time.split(separator: ":").map { value(String($0)) }
          return parts[0] * 60 + parts[1]
        }
        let spansBoth = failure.spanned.hasPrefix(from) && failure.spanned.hasSuffix(to)
        return spansBoth && minutes(from) > minutes(to)
          ? nil : "\(from) to \(to) against '\(failure.spanned)'"
      },
      try Template(
        "parse",
        "date must be a calendar date from 0001-01-01 to 9999-12-31, got (?<span>[0-9]{4}-[0-9]{2}-[0-9]{2})"
      ) { _, failure in
        isCalendarDate(failure.spanned) ? "\(failure.spanned) is a calendar date" : nil
      },
      try Template(
        "parse",
        "timezone must be UTC or an Area/Location name such as America/New_York, got (?<span>.+)"),
      try Template("parse", "duplicate '(?<keyword>except|until|starting|during|in)' clause") {
        groups, failure in
        groups["keyword"] == failure.spanned.lowercased()
          ? nil : "duplicate '\(groups["keyword"] ?? "")' but the span holds '\(failure.spanned)'"
      },
      try Template("parse", "'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'") {
        groups, failure in
        let (keyword, last) = (groups["keyword"] ?? "", groups["last"] ?? "")
        guard let k = clauseOrder.firstIndex(of: keyword), let l = clauseOrder.firstIndex(of: last),
          k < l, keyword == failure.spanned.lowercased()
        else { return "'\(keyword)' before '\(last)' with the span '\(failure.spanned)'" }
        return nil
      },
      try Template("parse", "unexpected '(?<span>.+)' after the schedule"),
      try Template(
        "parse",
        "until (?<month>\(month)) (?<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date"
      ) { groups, failure in
        let words = failure.spanned.unicodeScalars
          .split { " \t\r\n".unicodeScalars.contains($0) }.map {
            String(String.UnicodeScalarView($0))
          }
        let endsAtDay =
          !(failure.spanned.unicodeScalars.last.map { " \t\r\n".unicodeScalars.contains($0) }
          ?? true)
        let matches =
          endsAtDay && words.count == 3 && words[0].lowercased() == "until"
          && words[1].lowercased().hasPrefix(groups["month"] ?? "-")
          && words[2].first?.isASCII == true && words[2].first?.isNumber == true
          && String(value(words[2])) == groups["day"]
        return matches
          ? nil
          : "the span '\(failure.spanned)' is not 'until \(groups["month"] ?? "") \(groups["day"] ?? "")'"
      },
    ]
  }
}

/// Saturates, since a digit run can be thousands of digits long.
private func value(_ text: String?) -> Int64 {
  var result: Int64 = 0
  for scalar in (text ?? "").unicodeScalars {
    guard ("0"..."9").contains(scalar) else { break }
    result = min(result * 10 + Int64(scalar.value - 48), Int64.max / 20)
  }
  return result
}

private func isCalendarDate(_ text: String) -> Bool {
  let parts = text.split(separator: "-").map { value(String($0)) }
  guard parts.count == 3, parts[0] >= 1, (1...12).contains(parts[1]) else { return false }
  let leap = parts[0] % 4 == 0 && (parts[0] % 100 != 0 || parts[0] % 400 == 0)
  let lengths: [Int64] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let length = lengths[Int(parts[1]) - 1]
  return (1...length).contains(parts[2])
}
