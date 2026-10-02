import Foundation
import Hron
import Testing

@Suite struct ScheduleTests {
  static let everyMinute = try! Schedule.parse("every 1 min from 00:00 to 23:59")
  static let daily = try! Schedule.parse("every day at 09:00")

  @Test(arguments: [0, -1, Int.min])
  func nextOfNoneOrFewerIsEmpty(_ n: Int) {
    #expect(Self.daily.next(n, after: Date(timeIntervalSince1970: 0)) == [])
  }

  /// `n` only caps the count, so no room is reserved for it (spec/README.md, "Timestamps and
  /// counts").
  @Test func nextOfAHugeCountReturnsEveryOccurrenceAtOnce() throws {
    let schedule = try Schedule.parse("every year on jan 1 at 00:00 starting 9990-01-01")
    let all = schedule.next(Int.max, after: Date(timeIntervalSince1970: 0))
    #expect(all.count == 10)
    #expect(all.last == Timestamp.date("9999-01-01T00:00:00+00:00[UTC]"))
  }

  /// As seconds since the reference date: Foundation's `Date.description` traps on some of them.
  @Test(arguments: [
    .nan, .infinity, -.infinity, 1e300, -1e300, Date.distantPast.timeIntervalSinceReferenceDate,
    Timestamp.date("0001-01-01T23:59:59+00:00[UTC]").timeIntervalSinceReferenceDate,
    Timestamp.date("9999-12-30T00:00:00+00:00[UTC]").timeIntervalSinceReferenceDate,
  ])
  func aDateOutsideTheSupportedRangeHasNoOccurrences(_ seconds: Double) {
    let date = Date(timeIntervalSinceReferenceDate: seconds)
    let schedule = Self.everyMinute
    let inRange = Timestamp.date("2026-02-06T12:00:00+00:00[UTC]")
    #expect(schedule.next(after: date) == nil)
    #expect(schedule.previous(before: date) == nil)
    #expect(!schedule.matches(date))
    #expect(schedule.next(3, after: date) == [])
    #expect(Array(schedule.occurrences(after: date).prefix(3)) == [])
    #expect(Array(schedule.occurrences(after: date, through: inRange)) == [])
    #expect(Array(schedule.occurrences(after: inRange, through: date)) == [])
  }

  /// One nanosecond before 2001-01-01, which `timeIntervalSince1970` would round to the whole
  /// second 978307200.
  @Test func anInstantIsReadWithoutRoundingAcrossASecond() throws {
    let justBefore = Date(timeIntervalSinceReferenceDate: -1e-9)
    let schedule = try Schedule.parse("every day at 00:00")
    #expect(!schedule.matches(justBefore))
    #expect(schedule.next(after: justBefore) == Timestamp.date("2001-01-01T00:00:00+00:00[UTC]"))
  }

  @Test func theSupportedRangeIncludesItsStart() {
    let start = Timestamp.date("0001-01-02T00:00:00+00:00[UTC]")
    #expect(Self.everyMinute.matches(start))
    #expect(Self.everyMinute.next(after: start) == start.addingTimeInterval(60))
  }

  /// A fraction of a second rounds down, toward the past, even before 1970, where truncating
  /// toward zero would move -0.5 to 0.
  @Test func aFractionOfASecondBelongsToTheSecondBefore() {
    let justBeforeEpoch = Date(timeIntervalSince1970: -0.5)
    let epoch = Date(timeIntervalSince1970: 0)
    #expect(Self.everyMinute.next(after: justBeforeEpoch) == epoch)
    #expect(Self.everyMinute.previous(before: justBeforeEpoch) == Date(timeIntervalSince1970: -60))
    #expect(Self.everyMinute.matches(justBeforeEpoch))
    #expect(Self.everyMinute.previous(before: Date(timeIntervalSince1970: 0.5)) == epoch)
    #expect(
      Self.everyMinute.next(after: Date(timeIntervalSince1970: 0.5))
        == Date(timeIntervalSince1970: 60))
  }

  @Test func matchesTheWholeMinuteOnTheWallClock() {
    #expect(Self.daily.matches(Timestamp.date("2026-02-06T09:00:30+00:00[UTC]")))
    #expect(!Self.daily.matches(Timestamp.date("2026-02-06T09:01:30+00:00[UTC]")))
    #expect(!Self.daily.matches(Timestamp.date("2026-02-06T08:59:59+00:00[UTC]")))
  }

  @Test func occurrencesStayLazy() {
    let occurrences = Self.daily.occurrences(after: Date(timeIntervalSince1970: 0))
    let mapped = occurrences.map(\.timeIntervalSince1970)
    let filtered = occurrences.filter { _ in true }
    #expect(type(of: mapped) == LazyMapSequence<Occurrences, Double>.self)
    #expect(type(of: filtered) == LazyFilterSequence<Occurrences>.self)
    #expect(Array(mapped.prefix(2)) == [32400, 118800])
    #expect(Array(filtered.prefix(1)) == [Date(timeIntervalSince1970: 32400)])
  }

  @Test func occurrencesEndAtUntilOrTheEndOfTheSupportedRange() throws {
    let until = try Schedule.parse("every day at 09:00 until 2026-02-10")
    let from = Timestamp.date("2026-02-06T12:00:00+00:00[UTC]")
    #expect(Array(until.occurrences(after: from)).count == 4)
    let late = try Schedule.parse("every year on jan 1 at 00:00")
    #expect(
      Array(late.occurrences(after: Timestamp.date("9990-06-01T00:00:00+00:00[UTC]"))).count == 9)
  }

  @Test func occurrencesThroughIncludeTheEndButNotTheStart() {
    let from = Timestamp.date("2026-02-06T09:00:00+00:00[UTC]")
    let to = Timestamp.date("2026-02-08T09:00:00+00:00[UTC]")
    #expect(
      Array(Self.daily.occurrences(after: from, through: to)) == [
        Timestamp.date("2026-02-07T09:00:00+00:00[UTC]"), to,
      ])
    #expect(Array(Self.daily.occurrences(after: to, through: from)) == [])
  }

  @Test func iteratingTwiceGivesTheSameOccurrences() {
    let occurrences = Self.daily.occurrences(after: Date(timeIntervalSince1970: 0)).prefix(3)
    #expect(Array(occurrences) == Array(occurrences))
  }

  @Test func formattingInTheSchedulesZoneShowsItsWallClock() throws {
    let schedule = try Schedule.parse("every day at 09:00 in Asia/Tokyo")
    let next = try #require(schedule.next(after: Date(timeIntervalSince1970: 0)))
    #expect(
      Timestamp.format(next, in: schedule.timeZone, named: "Asia/Tokyo")
        == "1970-01-02T09:00:00+09:00[Asia/Tokyo]")
  }

  @Test func toCronLeavesTheZoneOut() throws {
    #expect(try Schedule.parse("every day at 09:00 in America/New_York").toCron() == "0 9 * * *")
  }

  @Test func startingIsAnISODate() throws {
    #expect(
      try Schedule.parse("every 2 days at 09:00 starting 2026-01-05").starting == "2026-01-05")
    #expect(Self.daily.starting == nil)
  }
}
