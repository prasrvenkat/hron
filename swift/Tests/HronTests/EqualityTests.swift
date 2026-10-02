import Hron
import Testing

/// spec/README.md, "Equality": equal parts, with equal hashes.
@Suite struct EqualityTests {
  @Test func equalPartsAreEqual() throws {
    let a = try Schedule.parse("every day at 9:00")
    let b = try Schedule.parse("every day at 09:00")
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
  }

  @Test(arguments: Spec.cases(in: "parse"))
  func parseEqualsParseOfItsDescription(_ spec: SpecCase) throws {
    let schedule = try Schedule.parse(spec.string("input"))
    let reparsed = try Schedule.parse(schedule.description)
    #expect(reparsed == schedule)
    #expect(reparsed.hashValue == schedule.hashValue)
  }

  @Test(arguments: Spec.cases(in: "cron", only: ["from_cron"]))
  func fromCronEqualsParseOfItsDescription(_ spec: SpecCase) throws {
    let schedule = try Schedule.fromCron(spec.string("cron"))
    let parsed = try Schedule.parse(schedule.description)
    #expect(parsed == schedule)
    #expect(parsed.hashValue == schedule.hashValue)
  }

  @Test(arguments: [
    ("every day at 09:00 except dec 25", "every day at 09:00"),
    ("every day at 09:00 until 2026-12-31", "every day at 09:00"),
    ("every day at 09:00 starting 2026-01-01", "every day at 09:00"),
    ("every day at 09:00 during jan", "every day at 09:00"),
    ("every day at 09:00 in UTC", "every day at 09:00"),
    ("every day at 09:00 except dec 25", "every day at 09:00 except dec 26"),
    ("every day at 09:00 until 2026-12-31", "every day at 09:00 until 2027-12-31"),
    ("every day at 09:00 starting 2026-01-01", "every day at 09:00 starting 2026-01-02"),
    ("every day at 09:00 during jan", "every day at 09:00 during feb"),
    ("every day at 09:00 in UTC", "every day at 09:00 in Etc/UTC"),
  ])
  func oneClauseApartIsNotEqual(_ a: String, _ b: String) throws {
    #expect(try Schedule.parse(a) != Schedule.parse(b))
  }

  @Test(arguments: [
    ("every day at 09:00, 17:00", "every day at 17:00, 09:00"),
    ("every day at 09:00, 09:00", "every day at 09:00"),
    ("every week on monday, friday at 09:00", "every week on friday, monday at 09:00"),
    ("every week on monday, monday at 09:00", "every week on monday at 09:00"),
    ("every day at 09:00 except dec 25, jan 1", "every day at 09:00 except jan 1, dec 25"),
    ("every day at 09:00 except dec 25, dec 25", "every day at 09:00 except dec 25"),
    ("every day at 09:00 during jan, feb", "every day at 09:00 during feb, jan"),
    ("every day at 09:00 during jan, jan", "every day at 09:00 during jan"),
    ("every month on the 1st, 15th at 09:00", "every month on the 15th, 1st at 09:00"),
  ])
  func listsCompareInOrderWithDuplicates(_ a: String, _ b: String) throws {
    #expect(try Schedule.parse(a) != Schedule.parse(b))
  }
}
