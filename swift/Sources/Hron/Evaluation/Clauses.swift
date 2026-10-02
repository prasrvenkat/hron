/// `during` applies to a candidate's target month; `except`, `until` and `starting` to its date
/// (spec/README.md, "Nearest weekday and `during`", "The `starting` clause").
struct Clauses: Sendable {
  /// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
  private static let namedUntilMaxYears = 8

  let during: [MonthName]
  let exceptMonthDays: [(month: Int, day: Int)]
  let exceptDates: [CivilDate]
  private(set) var until: CivilDate?
  let starting: CivilDate?

  init(_ schedule: Schedule) {
    var exceptMonthDays: [(month: Int, day: Int)] = []
    var exceptDates: [CivilDate] = []
    for exception in schedule.except {
      switch exception {
      case .named(let month, let day): exceptMonthDays.append((month.number, day))
      case .iso(let text):
        if let date = CivilDate(iso: text) {
          exceptDates.append(date)
        }
      }
    }
    self.during = schedule.during
    self.exceptMonthDays = exceptMonthDays
    self.exceptDates = exceptDates
    self.starting = schedule.startingDate
    self.until = schedule.until.flatMap { Self.resolve($0, starting: schedule.startingDate) }
  }

  /// A named until date is the first such date on or after the starting date (spec/README.md,
  /// "Named `until`"). Nil when no such date exists before the calendar ends, so nothing bounds
  /// the schedule.
  private static func resolve(_ until: UntilSpec, starting: CivilDate?) -> CivilDate? {
    switch until {
    case .iso(let text):
      return CivilDate(iso: text)
    case .named(let month, let day):
      guard let starting else { return nil }
      return (0...namedUntilMaxYears).lazy
        .compactMap { CivilDate(year: starting.year + $0, month: month.number, day: day) }
        .first { $0 >= starting }
    }
  }

  func allows(_ candidate: Candidate) -> Bool {
    let date = candidate.date
    return allows(month: candidate.targetMonth)
      && !exceptMonthDays.contains { $0 == (date.month, date.day) }
      && !exceptDates.contains(date)
      && (until.map { date <= $0 } ?? true)
      && (starting.map { date >= $0 } ?? true)
  }

  func allows(month: Int) -> Bool {
    during.isEmpty || during.contains { $0.number == month }
  }

  mutating func end(on date: CivilDate) {
    until = until.map { min($0, date) } ?? date
  }

  /// The one-off except date farthest along `direction`: the calendar repeats only beyond it
  /// (spec/README.md, "Search horizon").
  func farthestExceptDate(_ direction: Direction) -> CivilDate? {
    switch direction {
    case .forward: exceptDates.max()
    case .backward: exceptDates.min()
    }
  }

  func clamp(_ date: CivilDate, _ direction: Direction) -> CivilDate {
    switch direction {
    case .forward: starting.map { max(date, $0) } ?? date
    case .backward: until.map { min(date, $0) } ?? date
    }
  }

  func endsSearch(at date: CivilDate, _ direction: Direction) -> Bool {
    switch direction {
    case .forward: until.map { date > $0 } ?? false
    case .backward: starting.map { date < $0 } ?? false
    }
  }
}
