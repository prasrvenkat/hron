extension DayFilter {
  func matches(_ date: CivilDate) -> Bool {
    switch self {
    case .every: true
    case .weekday: !date.weekday.isWeekend
    case .weekend: date.weekday.isWeekend
    case .days(let days): days.contains(date.weekday)
    }
  }
}

extension DayOfMonthSpec {
  var days: ClosedRange<Int> {
    switch self {
    case .single(let day): day...day
    case .range(let start, let end): start...end
    }
  }
}

extension MonthTarget {
  func dates(year: Int, month: Int) -> [CivilDate] {
    switch self {
    case .days(let specs):
      specs.flatMap(\.days).compactMap { CivilDate(year: year, month: month, day: $0) }.sorted()
    case .lastDay:
      CivilDate(year: year, month: month, day: 1).map { [$0.lastOfMonth] } ?? []
    case .lastWeekday:
      lastWeekdayOfMonth(year: year, month: month).map { [$0] } ?? []
    case .nearestWeekday(let day, let direction):
      nearestWeekdayOfMonth(year: year, month: month, day: day, toward: direction).map { [$0] }
        ?? []
    case .ordinalWeekday(let ordinal, let weekday):
      ordinalWeekdayOfMonth(year: year, month: month, ordinal: ordinal, weekday: weekday).map {
        [$0]
      }
        ?? []
    }
  }
}

extension YearTarget {
  func date(year: Int) -> CivilDate? {
    switch self {
    case .date(let month, let day), .dayOfMonth(let day, let month):
      CivilDate(year: year, month: month.number, day: day)
    case .ordinalWeekday(let ordinal, let weekday, let month):
      ordinalWeekdayOfMonth(year: year, month: month.number, ordinal: ordinal, weekday: weekday)
    case .lastWeekday(let month):
      lastWeekdayOfMonth(year: year, month: month.number)
    }
  }
}

private func lastWeekdayOfMonth(year: Int, month: Int) -> CivilDate? {
  guard let last = CivilDate(year: year, month: month, day: 1)?.lastOfMonth else { return nil }
  switch last.weekday {
  case .saturday: return last.adding(days: -1)
  case .sunday: return last.adding(days: -2)
  default: return last
  }
}

private func ordinalWeekdayOfMonth(
  year: Int, month: Int, ordinal: OrdinalPosition, weekday: Weekday
) -> CivilDate? {
  guard let first = CivilDate(year: year, month: month, day: 1) else { return nil }
  let nth: Int64
  switch ordinal {
  case .first: nth = 1
  case .second: nth = 2
  case .third: nth = 3
  case .fourth: nth = 4
  case .fifth: nth = 5
  case .last:
    let last = first.lastOfMonth
    return last.adding(days: -daysFrom(weekday, to: last.weekday))
  }
  let date = first.adding(days: daysFrom(first.weekday, to: weekday) + 7 * (nth - 1))
  return date?.month == month ? date : nil
}

private func daysFrom(_ start: Weekday, to end: Weekday) -> Int64 {
  Int64(floorModulo(end.isoNumber - start.isoNumber, 7))
}

/// Nil when the month has no such day. Without a direction the weekday stays in the month; with
/// one it can cross into the adjacent month (spec/README.md, "Nearest weekday and `during`").
private func nearestWeekdayOfMonth(
  year: Int, month: Int, day: Int, toward direction: NearestDirection?
) -> CivilDate? {
  guard let date = CivilDate(year: year, month: month, day: day) else { return nil }
  let shift: Int64
  switch (date.weekday, direction) {
  case (.saturday, .next): shift = 2
  case (.saturday, .previous): shift = -1
  case (.saturday, nil): shift = day == 1 ? 2 : -1
  case (.sunday, .next): shift = 1
  case (.sunday, .previous): shift = -2
  case (.sunday, nil): shift = date == date.lastOfMonth ? -2 : 1
  default: shift = 0
  }
  return date.adding(days: shift)
}
