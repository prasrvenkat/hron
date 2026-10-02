import Foundation
import Hron
import Testing

/// The examples of swift/README.md, as written there. Each test records what the example prints
/// and checks it against the README's comments.
@Suite struct ReadmeTests {
  @Test func usage() throws {
    var lines: [String] = []
    func print(_ items: Any...) { lines.append(items.map { "\($0)" }.joined(separator: " ")) }

    let schedule = try Schedule.parse("every weekday at 9:00 in America/New_York")
    let now = try Date("2026-02-06T12:00:00Z", strategy: .iso8601)

    let next = schedule.next(after: now)  // 2026-02-06 14:00 UTC, 09:00 in New York
    let nextFive = schedule.next(5, after: now)  // up to 5 occurrences after now
    let previous = schedule.previous(before: now)  // 2026-02-05 14:00 UTC
    let matches = schedule.matches(now)  // false

    // A Date has no zone: format it in the schedule's zone to show the time it fires at.
    let style = Date.ISO8601FormatStyle(timeZone: schedule.timeZone)
    print(next!.formatted(style))  // 2026-02-06T09:00:00-0500

    // Occurrences are computed lazily, one at a time.
    for date in schedule.occurrences(after: now).prefix(3) {
      print(date.formatted(style))
    }

    print(schedule)  // every weekday at 09:00 in America/New_York
    print(try Schedule.parse("every day at 9:00").toCron())  // 0 9 * * *
    print(try Schedule.fromCron("0 16 * * 5L"))  // every month on the last friday at 16:00
    print(Schedule.validate("every day at 25:00"))  // false

    let expectedNext = try Date("2026-02-06T14:00:00Z", strategy: .iso8601)
    let expectedPrevious = try Date("2026-02-05T14:00:00Z", strategy: .iso8601)
    #expect(next == expectedNext)
    #expect(nextFive.count == 5)
    #expect(previous == expectedPrevious)
    #expect(!matches)
    #expect(
      lines == [
        "2026-02-06T09:00:00-0500",
        "2026-02-06T09:00:00-0500", "2026-02-09T09:00:00-0500", "2026-02-10T09:00:00-0500",
        "every weekday at 09:00 in America/New_York", "0 9 * * *",
        "every month on the last friday at 16:00", "false",
      ])
  }

  @Test func parts() throws {
    var lines: [String] = []
    func print(_ items: Any...) { lines.append(items.map { "\($0)" }.joined(separator: " ")) }

    let parts = try Schedule.parse(
      "every weekday at 9:00 except dec 25 starting 2026-01-01 during jan, dec in america/new_york")
    print(parts.timeZoneIdentifier ?? "none")  // America/New_York
    print(parts.starting ?? "none")  // 2026-01-01
    print(parts.until == nil)  // true
    print(parts.during == [.january, .december])  // true

    if case .dayRepeat(_, .weekday, let times) = parts.expression {
      print(times.map { "\($0.hour):\($0.minute)" })  // ["9:0"]
    }

    switch parts.except[0] {
    case .named(let month, let day): print(month, day)  // december 25
    case .iso(let date): print(date)
    @unknown default: break
    }

    #expect(
      lines == ["America/New_York", "2026-01-01", "true", "true", #"["9:0"]"#, "december 25"])
  }

  @Test func equality() throws {
    var lines: [String] = []
    func print(_ items: Any...) { lines.append(items.map { "\($0)" }.joined(separator: " ")) }

    let nine = try Schedule.parse("every day at 9:00")
    print(nine == (try Schedule.parse("every day at 09:00")))  // true
    print(nine.hashValue == (try Schedule.parse("every day at 09:00")).hashValue)  // true
    print(nine == (try Schedule.fromCron("0 9 * * *")))  // true
    print(
      (try Schedule.parse("every monday, friday at 09:00"))
        == (try Schedule.parse("every friday, monday at 09:00")))  // false

    #expect(lines == ["true", "true", "true", "false"])
  }

  @Test func errors() {
    var lines: [String] = []
    func print(_ items: Any...) { lines.append(items.map { "\($0)" }.joined(separator: " ")) }

    do {
      _ = try Schedule.parse("every weekday at 09:00 until dec 31")
    } catch {
      print(error.kind == .parse)  // true
      print(error.displayRich())
    }

    #expect(
      lines == [
        "true",
        """
        error: until dec 31 has no year: add a starting date, or use an ISO date
          every weekday at 09:00 until dec 31
                                 ^^^^^^^^^^^^ try: "until dec 31 starting YYYY-MM-DD"
        """,
      ])
  }

  @Test func cronConversion() throws {
    #expect(try Schedule.parse("every 15 min from 09:00 to 17:45").toCron() == "*/15 9-17 * * *")
    #expect(try Schedule.fromCron("0 9 * * 1-5").description == "every weekday at 09:00")
    let both = try #require(
      thrownError { () throws(HronError) in _ = try Schedule.fromCron("0 9 15 * 1") })
    #expect(both.kind == .cron)
    let uneven = try #require(
      thrownError { () throws(HronError) in _ = try Schedule.fromCron("*/7 * * * *") })
    #expect(uneven.message == "not expressible in hron: 216 times a day are too many to list")
  }

  @Test func datesBefore1582AreProlepticGregorian() throws {
    let schedule = try Schedule.parse("on 1582-10-10 at 12:00")
    let next = schedule.next(after: Timestamp.date("1500-01-01T00:00:00+00:00[UTC]"))
    let days = Timestamp.daysFromCivil(year: 1582, month: 10, day: 10)
    #expect(next == Date(timeIntervalSince1970: Double(days * 86_400 + 12 * 3600)))
  }

  @Test func everythingIsSendable() throws {
    func send(_ value: some Sendable) {}
    let schedule = try Schedule.parse("every day at 09:00")
    send(schedule)
    send(schedule.expression)
    send(schedule.occurrences(after: Date(timeIntervalSince1970: 0)))
    send(HronError.cron("m"))
  }
}
