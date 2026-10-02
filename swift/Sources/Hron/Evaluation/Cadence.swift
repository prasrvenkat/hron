struct Cadence: Sendable {
  enum Unit: Sendable {
    case day, week, month, year

    /// After 400 years the proleptic Gregorian calendar repeats.
    var per400Years: Int64 {
      switch self {
      case .day: 146_097
      case .week: 20_871
      case .month: 4_800
      case .year: 400
      }
    }
  }

  /// Slack beyond the horizon for the period one behind the first date's, where a search
  /// starts, and for a horizon that starts mid-period.
  private static let horizonMarginPeriods: Int64 = 2

  let unit: Unit
  let origin: CivilDate
  let interval: Int64
  let isSingle: Bool

  init(_ expression: ScheduleExpression, starting: CivilDate?) {
    let unit: Unit
    let interval: Int64
    var defaultOrigin = CivilDate.epoch
    switch expression {
    case .singleDate(.iso(let text), _):
      self.init(unit: .day, origin: CivilDate(iso: text), interval: 1, isSingle: true)
      return
    case .singleDate: (unit, interval) = (.year, 1)
    case .intervalRepeat: (unit, interval) = (.day, 1)
    case .dayRepeat(let n, _, _): (unit, interval) = (.day, Int64(n))
    case .weekRepeat(let n, _, _): (unit, interval, defaultOrigin) = (.week, Int64(n), .epochMonday)
    case .monthRepeat(let n, _, _): (unit, interval) = (.month, Int64(n))
    case .yearRepeat(let n, _, _): (unit, interval) = (.year, Int64(n))
    }
    let anchor = starting ?? defaultOrigin
    let origin: CivilDate? =
      switch unit {
      case .day: anchor
      case .week: anchor.adding(days: Int64(1 - anchor.weekday.isoNumber)) ?? anchor
      case .month: CivilDate(year: anchor.year, month: anchor.month, day: 1)
      case .year: CivilDate(year: anchor.year, month: 1, day: 1)
      }
    self.init(unit: unit, origin: origin, interval: interval, isSingle: false)
  }

  private init(unit: Unit, origin: CivilDate?, interval: Int64, isSingle: Bool) {
    self.unit = unit
    // A parsed ISO date and the first day of a date's month or year are calendar dates.
    self.origin = origin!
    self.interval = interval
    self.isSingle = isSingle
  }

  func period(of date: CivilDate) -> Int64 {
    switch unit {
    case .day: origin.days(until: date)
    case .week: floorDivide(origin.days(until: date), 7)
    case .month: date.monthIndex - origin.monthIndex
    case .year: Int64(date.year - origin.year)
    }
  }

  func start(ofPeriod k: Int64) -> CivilDate? {
    switch unit {
    case .day: origin.adding(days: k)
    case .week: k.multipliedReportingOverflow(by: 7).overflow ? nil : origin.adding(days: k * 7)
    case .month: CivilDate(firstOfMonthIndex: origin.monthIndex + k)
    case .year: CivilDate(firstOfYear: Int64(origin.year) + k)
    }
  }

  /// The first days of the aligned periods from `firstPeriod` in `direction`, through one search
  /// horizon beyond whichever of `firstPeriod` and `reach` is farther along it (spec/README.md,
  /// "Search horizon").
  func periodStarts(from firstPeriod: Int64, reach: Int64, _ direction: Direction) -> PeriodStarts {
    guard !isSingle else {
      return PeriodStarts(cadence: self, first: 0, step: 0, count: 1)
    }
    let first = align(firstPeriod, direction)
    let beyond = direction.sign * (align(reach, direction) - first)
    let count = horizonPeriods + Self.horizonMarginPeriods + max(beyond, 0) / interval
    return PeriodStarts(cadence: self, first: first, step: direction.sign * interval, count: count)
  }

  private func align(_ k: Int64, _ direction: Direction) -> Int64 {
    switch direction {
    case .forward: k + floorModulo(-k, interval)
    case .backward: k - floorModulo(k, interval)
    }
  }

  /// Aligned periods in lcm(400 years, interval units), after which both the calendar and the
  /// alignment repeat.
  private var horizonPeriods: Int64 {
    let cycle = unit.per400Years
    return cycle / greatestCommonDivisor(cycle, interval)
  }
}

private func greatestCommonDivisor(_ a: Int64, _ b: Int64) -> Int64 {
  b == 0 ? a : greatestCommonDivisor(b, a % b)
}

/// Leading periods past the calendar's edge are skipped, as when the one a search starts from,
/// behind the first date's, lies past its end; after that, the first period past the edge ends
/// the search.
struct PeriodStarts: Sequence, IteratorProtocol {
  let cadence: Cadence
  let first: Int64
  let step: Int64
  let count: Int64
  private var index: Int64 = 0
  private var started = false

  init(cadence: Cadence, first: Int64, step: Int64, count: Int64) {
    self.cadence = cadence
    self.first = first
    self.step = step
    self.count = count
  }

  mutating func next() -> CivilDate? {
    while index < count {
      let start = cadence.start(ofPeriod: first + index * step)
      index += 1
      if let start {
        started = true
        return start
      }
      if started {
        index = count
      }
    }
    return nil
  }
}
