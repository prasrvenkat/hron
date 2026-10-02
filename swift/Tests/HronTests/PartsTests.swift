import Hron
import Testing

@Suite struct PartsTests {
  @Test(arguments: [
    (
      "every 30 min from 09:00 to 17:00",
      ScheduleExpression.intervalRepeat(
        interval: 30, unit: .minutes, from: time(9, 0), to: time(17, 0), dayFilter: nil)
    ),
    (
      "every 2 hours from 00:00 to 23:59 on weekend",
      .intervalRepeat(
        interval: 2, unit: .hours, from: time(0, 0), to: time(23, 59), dayFilter: .weekend)
    ),
    ("every 3 days at 9:30", .dayRepeat(interval: 3, days: .every, times: [time(9, 30)])),
    (
      "every mon, fri at 09:00, 17:00",
      .dayRepeat(interval: 1, days: .days([.monday, .friday]), times: [time(9, 0), time(17, 0)])
    ),
    (
      "every 2 weeks on tue at 08:00",
      .weekRepeat(interval: 2, days: [.tuesday], times: [time(8, 0)])
    ),
    (
      "every month on the 1st to 5th, 15th at 09:00",
      .monthRepeat(
        interval: 1, target: .days([.range(start: 1, end: 5), .single(15)]), times: [time(9, 0)])
    ),
    (
      "every month on the previous nearest weekday to 1st at 09:00",
      .monthRepeat(
        interval: 1, target: .nearestWeekday(day: 1, direction: .previous), times: [time(9, 0)])
    ),
    (
      "every month on the last friday at 09:00",
      .monthRepeat(
        interval: 1, target: .ordinalWeekday(ordinal: .last, weekday: .friday),
        times: [time(9, 0)])
    ),
    (
      "every year on dec 25 at 00:00",
      .yearRepeat(interval: 1, target: .date(month: .december, day: 25), times: [time(0, 0)])
    ),
    (
      "every year on the 25th of dec at 00:00",
      .yearRepeat(interval: 1, target: .dayOfMonth(day: 25, month: .december), times: [time(0, 0)])
    ),
    (
      "every year on the third monday of jan at 00:00",
      .yearRepeat(
        interval: 1, target: .ordinalWeekday(ordinal: .third, weekday: .monday, month: .january),
        times: [time(0, 0)])
    ),
    (
      "on 2026-03-15 at 14:30",
      .singleDate(date: .iso("2026-03-15"), times: [time(14, 30)])
    ),
    (
      "on mar 15 at 14:30", .singleDate(date: .named(month: .march, day: 15), times: [time(14, 30)])
    ),
  ])
  func expression(_ input: String, _ expected: ScheduleExpression) throws {
    #expect(try Schedule.parse(input).expression == expected)
  }

  @Test func clauses() throws {
    let schedule = try Schedule.parse(
      "every day at 09:00 except dec 25, 2026-01-01 until jan 31 starting 2026-01-05 during jan, dec"
    )
    #expect(schedule.except == [.named(month: .december, day: 25), .iso("2026-01-01")])
    #expect(schedule.until == .named(month: .january, day: 31))
    #expect(schedule.starting == "2026-01-05")
    #expect(schedule.during == [.january, .december])
    #expect(try Schedule.parse("every day at 09:00 until 2026-12-31").until == .iso("2026-12-31"))
  }

  @Test func noClausesGiveEmptyListsAndNil() throws {
    let schedule = try Schedule.parse("every day at 09:00")
    #expect(schedule.except.isEmpty && schedule.during.isEmpty)
    #expect(schedule.until == nil && schedule.starting == nil && schedule.timeZoneIdentifier == nil)
  }
}

private func time(_ hour: Int, _ minute: Int) -> TimeOfDay {
  // TimeOfDay has no public initializer, so the tests read one from a parsed schedule.
  let schedule = try! Schedule.parse("every day at \(hour):\(minute < 10 ? "0" : "")\(minute)")
  guard case .dayRepeat(_, _, let times) = schedule.expression else { fatalError() }
  return times[0]
}
