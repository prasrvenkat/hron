import Foundation

enum DailyTimes {
  /// Minutes after midnight, each shifted out of a gap.
  case fixed([Int])
  /// Minutes after midnight, each skipped in a gap.
  case slots([Int])

  init(_ expression: ScheduleExpression) {
    switch expression {
    case .intervalRepeat(let interval, let unit, let from, let to, _):
      self = .slots(intervalSlots(interval: interval, unit: unit, from: from, to: to))
    case .dayRepeat(_, _, let times), .weekRepeat(_, _, let times),
      .monthRepeat(_, _, let times), .singleDate(_, let times), .yearRepeat(_, _, let times):
      self = .fixed(times.map(\.minuteOfDay))
    }
  }

  /// How many dates past its scheduled date an occurrence can land: a gap pushes a fixed time
  /// forward, at most onto the next date, as no gap in tzdata exceeds 24 hours; it skips a slot.
  var maxShiftDays: Int64 {
    switch self {
    case .fixed: 1
    case .slots: 0
    }
  }

  func nearest(
    on date: CivilDate, beyond now: Moment, going direction: Direction, in zone: TimeZone
  ) -> Int64? {
    switch self {
    case .fixed(let minutes):
      // Every time is compared: one shifted out of a gap can land after a later wall time.
      let instants = minutes.map { zone.fixedTime(on: date, minuteOfDay: $0) }
        .filter { direction.lies($0, beyond: now) }
      return direction == .forward ? instants.min() : instants.max()
    case .slots(let minutes):
      let slots = minutes.lazy.map { zone.slot(on: date, minuteOfDay: $0) }
      switch direction {
      case .forward:
        let first = partitionPoint(slots) { !now.isBefore($0.key) }
        return slots[first...].lazy.compactMap(\.instant).first
      case .backward:
        let end = partitionPoint(slots) { now.isAfter($0.key) }
        return slots[..<end].reversed().lazy.compactMap(\.instant).first
      }
    }
  }
}

private func partitionPoint<C: RandomAccessCollection>(
  _ elements: C, _ isBelow: (C.Element) -> Bool
) -> C.Index {
  var low = elements.startIndex
  var count = elements.count
  while count > 0 {
    let half = count / 2
    let middle = elements.index(low, offsetBy: half)
    if isBelow(elements[middle]) {
      low = elements.index(after: middle)
      count -= half + 1
    } else {
      count = half
    }
  }
  return low
}

func intervalSlots(interval: Int, unit: IntervalUnit, from: TimeOfDay, to: TimeOfDay) -> [Int] {
  let step: Int64
  switch unit {
  case .minutes: step = Int64(interval)
  case .hours: step = Int64(interval) * 60
  }
  let first = Int64(from.minuteOfDay)
  return (0...(Int64(to.minuteOfDay) - first) / step).map { Int(first + $0 * step) }
}
