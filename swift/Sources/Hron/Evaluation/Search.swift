import Foundation

/// A date the expression fires on, with the month whose day it names. They differ only when a
/// directional nearest weekday crosses into the adjacent month.
struct Candidate {
  let date: CivilDate
  let targetMonth: Int
}

/// How far now's wall date can trail a date that has begun: one, on the second pass of a
/// fall-back across midnight. No overlap in tzdata exceeds 24 hours.
private let maxOverlapDays: Int64 = 1

struct Search: Sendable {
  private let expression: ScheduleExpression
  private let zone: TimeZone
  private let cadence: Cadence
  private let times: DailyTimes
  private var clauses: Clauses

  init(_ schedule: Schedule) {
    expression = schedule.expression
    zone = schedule.timeZone
    cadence = Cadence(schedule.expression, starting: schedule.startingDate)
    times = DailyTimes(schedule.expression)
    clauses = Clauses(schedule)
  }

  /// In Unix seconds.
  func nearest(_ now: Moment, _ direction: Direction) -> Int64? {
    guard let nowDate = zone.wallDate(ofUnixSeconds: now.seconds) else { return nil }
    let firstDate = clauses.clamp(nowDate, direction)
    // A nearest weekday or a DST shift can move an occurrence out of the period it is
    // scheduled in, so the search starts one period back.
    let firstPeriod = cadence.period(of: firstDate) - direction.sign
    let reach = clauses.farthestExceptDate(direction).map { cadence.period(of: $0) } ?? firstPeriod
    let shift = times.maxShiftDays
    var best: (instant: Int64, landing: CivilDate)?
    search: for start in cadence.periodStarts(from: firstPeriod, reach: reach, direction) {
      if rejectsPeriod(start) {
        continue
      }
      let candidates = candidates(inPeriodStarting: start)
      for candidate in direction == .forward ? candidates : candidates.reversed() {
        let beaten = best.map {
          !couldBeat(candidate.date, $0.landing, direction, shift: shift)
        }
        if beaten ?? false || clauses.endsSearch(at: candidate.date, direction) {
          break search
        }
        if isBehind(candidate.date, nowDate, direction, shift: shift)
          || !clauses.allows(candidate)
        {
          continue
        }
        guard
          let instant = times.nearest(
            on: candidate.date, beyond: now, going: direction, in: zone),
          best.map({ direction.precedes(instant, $0.instant) }) ?? true,
          let landing = zone.wallDate(ofUnixSeconds: instant)
        else { continue }
        best = (instant, landing)
      }
    }
    guard let best, Moment.supportedSeconds.contains(best.instant) else { return nil }
    return best.instant
  }

  /// Defined through the forward search, so the two can never disagree about what an occurrence
  /// is (spec/README.md, "matches is true exactly when the minute containing t is an
  /// occurrence").
  func matches(_ moment: Moment) -> Bool {
    let wallSecond = floorModulo(moment.seconds + zone.offset(atUnixSeconds: moment.seconds), 60)
    let minute = moment.seconds - wallSecond
    guard let minuteDate = zone.wallDate(ofUnixSeconds: minute) else { return false }
    var search = self
    // An occurrence never lands before the date it is scheduled on, so one at this minute is
    // scheduled on or before the minute's wall date.
    search.clauses.end(on: minuteDate)
    let justBefore = Moment(seconds: minute - 1, hasFraction: true)
    return search.nearest(justBefore, .forward) == minute
  }

  /// A day or month period's candidates all target its own month, so one whose month `during`
  /// rejects holds nothing.
  private func rejectsPeriod(_ start: CivilDate) -> Bool {
    switch cadence.unit {
    case .day, .month: !clauses.allows(month: start.month)
    case .week, .year: false
    }
  }

  private func candidates(inPeriodStarting start: CivilDate) -> [Candidate] {
    let periodMonth: Int? = if case .monthRepeat = expression { start.month } else { nil }
    return dates(inPeriodStarting: start).map {
      Candidate(date: $0, targetMonth: periodMonth ?? $0.month)
    }
  }

  private func dates(inPeriodStarting start: CivilDate) -> [CivilDate] {
    switch expression {
    case .intervalRepeat(_, _, _, _, let dayFilter):
      (dayFilter.map { $0.matches(start) } ?? true) ? [start] : []
    case .dayRepeat(_, let days, _):
      days.matches(start) ? [start] : []
    case .weekRepeat(_, let days, _):
      days.compactMap { start.adding(days: Int64($0.isoNumber - 1)) }.sorted()
    case .monthRepeat(_, let target, _):
      target.dates(year: start.year, month: start.month)
    case .yearRepeat(_, let target, _):
      target.date(year: start.year).map { [$0] } ?? []
    case .singleDate(.named(let month, let day), _):
      CivilDate(year: start.year, month: month.number, day: day).map { [$0] } ?? []
    case .singleDate(.iso, _):
      [start]
    }
  }
}

/// Whether an occurrence scheduled on `date` can precede, in `direction`, the best one, which
/// landed on `landing`. An occurrence lands from its scheduled date to `shift` dates after it,
/// on a first pass, and first passes keep wall-clock order.
private func couldBeat(
  _ date: CivilDate, _ landing: CivilDate, _ direction: Direction, shift: Int64
) -> Bool {
  switch direction {
  case .forward: date <= landing
  case .backward: date.days(until: landing) <= shift
  }
}

/// True only when every occurrence scheduled on `date` lies behind `now`, whose wall date is
/// `nowDate`, in `direction`; false proves nothing.
private func isBehind(
  _ date: CivilDate, _ nowDate: CivilDate, _ direction: Direction, shift: Int64
) -> Bool {
  switch direction {
  case .forward: date.days(until: nowDate) > shift
  case .backward: nowDate.days(until: date) > maxOverlapDays
  }
}
