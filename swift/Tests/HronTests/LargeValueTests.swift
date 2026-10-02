import Foundation
import Hron
import Testing

/// Each case takes a value past 2147483647 through hron's arithmetic, where an `Int` of 32 bits,
/// as on Apple Watch and wasm32, would overflow. `just test-swift-32` runs them at 32 bits.
@Suite struct LargeValueTests {
  static let now = Timestamp.date(Spec.defaultNow)

  @Test func theFirstSupportedSecondIsReached() throws {
    let first = Timestamp.date("0001-01-02T00:00:00+00:00[UTC]")
    let schedule = try Schedule.parse("every 1 min from 00:00 to 23:59")
    #expect(schedule.previous(before: first.addingTimeInterval(30)) == first)
    #expect(schedule.previous(before: first) == nil)
  }

  @Test func theLastSupportedMinuteIsReached() throws {
    let last = Timestamp.date("9999-12-29T23:59:00+00:00[UTC]")
    let schedule = try Schedule.parse("every 1 min from 00:00 to 23:59")
    #expect(schedule.next(after: last.addingTimeInterval(-60)) == last)
    #expect(schedule.matches(last.addingTimeInterval(59)))
    #expect(schedule.next(after: last) == nil)
  }

  @Test(arguments: [
    ("every 2147483647 days at 00:00", "1970-01-01T00:00:00+00:00[UTC]"),
    ("every 2147483647 weeks on monday at 00:00", "1970-01-05T00:00:00+00:00[UTC]"),
    ("every 2147483647 months on the 1st at 00:00", "1970-01-01T00:00:00+00:00[UTC]"),
    ("every 2147483647 years on jan 1 at 00:00", "1970-01-01T00:00:00+00:00[UTC]"),
  ])
  func theLargestIntervalFiresOnlyAtItsOrigin(_ expression: String, _ origin: String) throws {
    let schedule = try Schedule.parse(expression)
    #expect(schedule.previous(before: Self.now) == Timestamp.date(origin))
    #expect(schedule.previous(before: Timestamp.date(origin)) == nil)
    #expect(schedule.next(after: Self.now) == nil)
  }

  @Test(arguments: [
    "every 2147483647 min from 00:00 to 23:59", "every 2147483647 hours from 00:00 to 23:59",
  ])
  func theLargestIntervalWithinADayFiresOnlyAtItsStart(_ expression: String) throws {
    let schedule = try Schedule.parse(expression)
    #expect(schedule.next(after: Self.now) == Timestamp.date("2026-02-07T00:00:00+00:00[UTC]"))
    #expect(try schedule.toCron() == "0 0 * * *")
  }

  @Test(arguments: ["2147483648", "9999999999"])
  func aTenDigitNumberAboveTheLimitIsALexError(_ number: String) throws {
    let input = "every \(number) days at 00:00"
    let error = try #require(thrownError { () throws(HronError) in _ = try Schedule.parse(input) })
    #expect(error.kind == .lex)
    #expect(error.message == "number must be at most 2147483647")
    #expect(error.span == HronError.Span(start: 6, end: 16))
  }
}
