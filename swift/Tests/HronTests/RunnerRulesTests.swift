import Testing

/// The runner fails what it cannot check (spec/README.md, "Writing a runner").
@Suite struct RunnerRulesTests {
  @Test func anUnknownSectionFails() {
    guard case .object(let tests) = Spec.tests, case .object(var cron) = tests["cron"] else {
      Issue.record("spec/tests.json has no cron section")
      return
    }
    var withSections = tests
    withSections["new_section"] = .object([:])
    cron["new_section"] = .object([:])
    withSections["cron"] = .object(cron)
    #expect(
      ConformanceTests.sectionProblems(of: .object(withSections)) == [
        "spec section 'new_section' is not known to this runner",
        "spec section 'cron.new_section' is not known to this runner",
      ])
  }

  @Test func anUnknownFieldFails() {
    let spec = SpecCase(
      section: "eval.matches", index: 0,
      fields: .object(["expression": .string("x"), "expected": .bool(true), "unknown": .null]))
    #expect(
      spec.fieldProblems(ConformanceTests.matchesFields) == [
        "eval.matches case 0: field 'unknown' is not known to this runner"
      ])
  }

  @Test func aCaseWithoutAnAssertionFails() {
    let spec = SpecCase(
      section: "eval.day_repeat", index: 0, fields: .object(["expression": .string("x")]))
    #expect(
      spec.fieldProblems(ConformanceTests.nextFields) == [
        "eval.day_repeat case 0 has none of the assertion fields"
          + " [\"next\", \"next_date\", \"next_n\", \"next_n_length\"]"
      ])
  }

  @Test func aNullAssertionIsAnAssertion() {
    let spec = SpecCase(
      section: "eval.day_repeat", index: 0,
      fields: .object(["expression": .string("x"), "next": .null]))
    #expect(spec.fieldProblems(ConformanceTests.nextFields) == [])
  }

  static let wrongTypes: [(FieldSchema, [String: JSON], String)] = [
    (
      ConformanceTests.betweenFields,
      ["expression": .string("x"), "from": .string("x"), "to": .string("x"), "expected": .null],
      "field 'expected' is not a list"
    ),
    (
      ConformanceTests.betweenFields,
      [
        "expression": .string("x"), "from": .string("x"), "to": .string("x"),
        "expected_count": .number(0.5),
      ],
      "field 'expected_count' is not an integer"
    ),
    (
      ConformanceTests.nextFields, ["expression": .string("x"), "next_n": .null],
      "field 'next_n' is not a list"
    ),
    (
      ConformanceTests.nextFields,
      ["expression": .string("x"), "next_n": .array([]), "next_n_count": .number(0.5)],
      "field 'next_n_count' is not an integer"
    ),
    (
      ConformanceTests.nextFields, ["expression": .string("x"), "next": .bool(false)],
      "field 'next' is not a timestamp or null"
    ),
    (
      ConformanceTests.matchesFields,
      ["expression": .string("x"), "datetime": .string("x"), "expected": .null],
      "field 'expected' is not a boolean"
    ),
  ]

  @Test(arguments: wrongTypes)
  func aFieldOfTheWrongTypeFails(_ schema: FieldSchema, _ fields: [String: JSON], _ problem: String)
  {
    let spec = SpecCase(section: "eval.section", index: 0, fields: .object(fields))
    #expect(spec.fieldProblems(schema) == ["eval.section case 0: \(problem)"])
  }

  @Test func anUnknownInvariantRuleFails() throws {
    let check = Invariants(
      schedule: try .parse("every day at 09:00"), now: Timestamp.date(Spec.defaultNow), count: 5)
    #expect(check.failure(of: "a_new_rule") == "rule is not implemented by this runner")
    #expect(check.failure(of: "next_matches") == nil)
  }
}
