import Foundation
import Hron
import Testing

/// Every case of spec/tests.json, with the runner rules of spec/README.md, "Writing a runner".
@Suite struct ConformanceTests {
  /// Every other eval section holds nextFrom cases (spec/README.md, "Writing a runner").
  static let evalSections = ["matches", "occurrences", "between", "previous_from"]

  static let parseFields = FieldSchema(
    inputs: ["input": .string], assertions: ["canonical": .string])
  static let parseErrorFields = FieldSchema(
    inputs: ["input": .string], assertions: ["error": .object, "display": .string])
  static let nextFields = FieldSchema(
    inputs: ["expression": .string, "now": .string, "next_n_count": .integer],
    assertions: [
      "next": .timestampOrNull, "next_date": .string, "next_n": .list, "next_n_length": .integer,
    ])
  static let matchesFields = FieldSchema(
    inputs: ["expression": .string, "datetime": .string], assertions: ["expected": .boolean])
  static let occurrencesFields = FieldSchema(
    inputs: ["expression": .string, "from": .string, "take": .integer],
    assertions: ["expected": .list])
  static let betweenFields = FieldSchema(
    inputs: ["expression": .string, "from": .string, "to": .string],
    assertions: ["expected": .list, "expected_count": .integer])
  static let previousFields = FieldSchema(
    inputs: ["expression": .string, "now": .string], assertions: ["expected": .timestampOrNull])
  static let toCronFields = FieldSchema(inputs: ["hron": .string], assertions: ["cron": .string])
  static let toCronErrorFields = FieldSchema(
    inputs: ["hron": .string], assertions: ["error": .string])
  static let fromCronFields = FieldSchema(inputs: ["cron": .string], assertions: ["hron": .string])
  static let fromCronErrorFields = FieldSchema(
    inputs: ["cron": .string], assertions: ["error": .string])
  static let cronRoundtripFields = FieldSchema(inputs: ["hron": .string], assertions: [:])
  static let invariantFields = FieldSchema(
    inputs: ["expression": .string, "now": .string], assertions: [:])

  @Test func everySectionIsKnown() {
    #expect(Self.sectionProblems(of: Spec.tests) == [])
  }

  static func sectionProblems(of tests: JSON) -> [String] {
    let topLevel = [
      "$schema", "version", "description", "now", "_eval_assertion_types", "_behavioral_notes",
      "parse", "parse_errors", "eval", "cron", "invariants",
    ]
    let cron = [
      "description", "to_cron", "to_cron_errors", "from_cron", "from_cron_errors", "roundtrip",
    ]
    return tests.keys.filter { !topLevel.contains($0) }.map {
      "spec section '\($0)' is not known to this runner"
    }
      + (tests["cron"]?.keys ?? []).filter { !cron.contains($0) }.map {
        "spec section 'cron.\($0)' is not known to this runner"
      }
  }

  @Test(arguments: Spec.cases(in: "parse"))
  func parse(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.parseFields) else { return }
    let canonical = spec.string("canonical")
    let schedule = try Schedule.parse(spec.string("input"))
    #expect(schedule.description == canonical)
    #expect(try Schedule.parse(canonical).description == canonical)
  }

  @Test(arguments: Spec.flatCases(in: "parse_errors"))
  func parseError(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.parseErrorFields) else { return }
    let input = spec.string("input")
    let expected = try #require(spec["error"])
    for key in expected.keys where !["kind", "message", "span", "suggestion"].contains(key) {
      Issue.record("error field '\(key)' is not known to this runner")
    }
    #expect(!Schedule.validate(input))
    let error = try #require(thrownError { () throws(HronError) in _ = try Schedule.parse(input) })
    #expect(name(of: error.kind) == expected["kind"]?.string)
    #expect(error.message == expected["message"]?.string)
    let span = try #require(error.span)
    #expect([span.start, span.end] == expected["span"]?.array?.compactMap(\.int))
    if let suggestion = expected["suggestion"], !suggestion.isNull {
      let text = try #require(suggestion.string, "suggestion must be a string or null")
      #expect(error.suggestion == text)
    } else {
      #expect(error.suggestion == nil)
    }
    #expect(error.input == input)
    if let display = spec["display"] {
      #expect(error.displayRich() == display.string)
    }
  }

  @Test(arguments: Spec.cases(in: "eval", excluding: evalSections))
  func next(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.nextFields) else { return }
    let schedule = try Schedule.parse(spec.string("expression"))
    let now = Timestamp.date(spec["now"]?.string ?? Spec.defaultNow)
    if let expected = spec["next"] {
      expectTimestamp(schedule.next(after: now), expected, schedule)
    }
    if let expected = spec["next_date"] {
      let next = try #require(schedule.next(after: now))
      #expect(Timestamp.wallDate(next, in: schedule.timeZone) == expected.string)
    }
    let count = spec["next_n_count"]?.int
    if let expected = spec["next_n"]?.array {
      #expect(!expected.isEmpty || count != nil, "an empty next_n asserts nothing without a count")
      expectTimestamps(schedule.next(count ?? expected.count, after: now), expected, schedule)
    }
    if let length = spec["next_n_length"] {
      let count = try #require(count, "next_n_length needs next_n_count")
      #expect(schedule.next(count, after: now).count == length.int)
    }
  }

  @Test(arguments: Spec.cases(in: "eval", only: ["matches"]))
  func matches(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.matchesFields) else { return }
    let schedule = try Schedule.parse(spec.string("expression"))
    let datetime = Timestamp.date(spec.string("datetime"))
    #expect(schedule.matches(datetime) == spec["expected"]?.bool)
  }

  @Test(arguments: Spec.cases(in: "eval", only: ["occurrences"]))
  func occurrences(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.occurrencesFields) else { return }
    let schedule = try Schedule.parse(spec.string("expression"))
    let from = Timestamp.date(spec.string("from"))
    let take = try #require(spec["take"]?.int)
    let expected = try #require(spec["expected"]?.array)
    expectTimestamps(Array(schedule.occurrences(after: from).prefix(take)), expected, schedule)
  }

  @Test(arguments: Spec.cases(in: "eval", only: ["between"]))
  func between(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.betweenFields) else { return }
    let schedule = try Schedule.parse(spec.string("expression"))
    let from = Timestamp.date(spec.string("from"))
    let to = Timestamp.date(spec.string("to"))
    let results = Array(schedule.occurrences(after: from, through: to))
    if let expected = spec["expected"]?.array {
      expectTimestamps(results, expected, schedule)
    }
    if let count = spec["expected_count"] {
      #expect(results.count == count.int)
    }
  }

  @Test(arguments: Spec.cases(in: "eval", only: ["previous_from"]))
  func previous(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.previousFields) else { return }
    let schedule = try Schedule.parse(spec.string("expression"))
    let now = Timestamp.date(spec.string("now"))
    expectTimestamp(schedule.previous(before: now), try #require(spec["expected"]), schedule)
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["to_cron"]))
  func toCron(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.toCronFields) else { return }
    #expect(try Schedule.parse(spec.string("hron")).toCron() == spec.string("cron"))
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["to_cron_errors"]))
  func toCronError(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.toCronErrorFields) else { return }
    let schedule = try Schedule.parse(spec.string("hron"))
    expectCronError(spec) { () throws(HronError) in _ = try schedule.toCron() }
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["from_cron"]))
  func fromCron(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.fromCronFields) else { return }
    #expect(try Schedule.fromCron(spec.string("cron")).description == spec.string("hron"))
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["from_cron_errors"]))
  func fromCronError(_ spec: SpecCase) {
    guard spec.fieldsAreReadable(Self.fromCronErrorFields) else { return }
    let cron = spec.string("cron")
    expectCronError(spec) { () throws(HronError) in _ = try Schedule.fromCron(cron) }
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["roundtrip"]))
  func cronRoundtrip(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.cronRoundtripFields) else { return }
    let cron = try Schedule.parse(spec.string("hron")).toCron()
    #expect(try Schedule.fromCron(cron).toCron() == cron)
  }

  @Test(arguments: Spec.flatCases(in: "invariants"))
  func invariants(_ spec: SpecCase) throws {
    guard spec.fieldsAreReadable(Self.invariantFields) else { return }
    let rules = try #require(Spec.tests["invariants"]?["rules"]).keys
    #expect(!rules.isEmpty)
    let count = try #require(Spec.tests["invariants"]?["count"]?.int)
    let schedule = try Schedule.parse(spec.string("expression"))
    let now = Timestamp.date(spec.string("now"))
    let check = Invariants(schedule: schedule, now: now, count: count)
    for rule in rules {
      if let failure = check.failure(of: rule) {
        Issue.record("\(rule): \(failure)")
      }
    }
  }

  private func expectCronError(
    _ spec: SpecCase, sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws(HronError) -> Void
  ) {
    do {
      try body()
      Issue.record("expected a cron error", sourceLocation: sourceLocation)
    } catch {
      #expect(error.kind == .cron, sourceLocation: sourceLocation)
      #expect(error.message == spec.string("error"), sourceLocation: sourceLocation)
    }
  }
}

/// Swift compares instants, as `Date` has no zone (spec/README.md, "Writing a runner"). Each
/// expected timestamp's zone and offset are checked too, against the schedule's `timeZone`,
/// in which a caller formats the results.
func expectTimestamp(
  _ got: Date?, _ expected: JSON, _ schedule: Schedule,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard let text = expected.string else {
    #expect(
      expected.isNull && got == nil, "got \(String(describing: got))",
      sourceLocation: sourceLocation)
    return
  }
  guard let got else {
    Issue.record("got nil, expected \(text)", sourceLocation: sourceLocation)
    return
  }
  #expect(
    Timestamp.format(got, in: schedule.timeZone, named: schedule.timeZoneIdentifier ?? "UTC")
      == text,
    sourceLocation: sourceLocation)
  #expect(got == Timestamp.parse(text)?.date, sourceLocation: sourceLocation)
}

func expectTimestamps(
  _ got: [Date], _ expected: [JSON], _ schedule: Schedule,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(got.count == expected.count, "got \(got)", sourceLocation: sourceLocation)
  for (date, text) in zip(got, expected) {
    expectTimestamp(date, text, schedule, sourceLocation: sourceLocation)
  }
}

func name(of kind: HronError.Kind) -> String {
  switch kind {
  case .lex: "lex"
  case .parse: "parse"
  case .eval: "eval"
  case .cron: "cron"
  }
}
