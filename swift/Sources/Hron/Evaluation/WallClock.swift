import Foundation

extension TimeZone {
  func offset(atUnixSeconds seconds: Int64) -> Int64 {
    Int64(secondsFromGMT(for: date(fromUnixSeconds: seconds)))
  }

  func wallDate(ofUnixSeconds seconds: Int64) -> CivilDate? {
    CivilDate(
      daysSinceEpoch: floorDivide(seconds + offset(atUnixSeconds: seconds), secondsPerDay))
  }

  /// The instant a fixed time names on `date`. One in a spring-forward gap shifts forward by
  /// the gap's length (spec/README.md, "DST spring-forward (gaps)").
  func fixedTime(on date: CivilDate, minuteOfDay minute: Int) -> Int64 {
    resolveWallClock(wallSeconds(date, minute)).instant
  }

  /// An interval slot on `date`, which a spring-forward gap skips (spec/README.md, "Interval
  /// slots in a spring-forward gap"). A skipped slot sits at the instant its gap ends, so keys
  /// never decrease in wall-clock order and one binary search finds the slots on either side of
  /// an instant.
  func slot(on date: CivilDate, minuteOfDay minute: Int) -> (key: Int64, instant: Int64?) {
    let wall = wallSeconds(date, minute)
    let resolved = resolveWallClock(wall)
    guard resolved.inGap else { return (resolved.instant, resolved.instant) }
    // In a gap, the wall time read at the offset before it gives an instant at or after the
    // gap ends, at the offset after it.
    let before = wall - resolved.instant
    let after = offset(atUnixSeconds: resolved.instant)
    return (gapEnd(wall: wall, offsetBefore: before, offsetAfter: after), nil)
  }

  private func wallSeconds(_ date: CivilDate, _ minuteOfDay: Int) -> Int64 {
    date.daysSinceEpoch * secondsPerDay + Int64(minuteOfDay) * 60
  }

  /// A wall time a fall-back repeats takes its first pass (spec/README.md, "DST fall-back
  /// (ambiguous times)"); one in a gap takes the offset before the gap, which shifts it forward
  /// by the gap's length. This assumes at most one offset change within a day of the wall time;
  /// tzdata has none closer than about four days.
  private func resolveWallClock(_ wall: Int64) -> (instant: Int64, inGap: Bool) {
    let offsetBefore = offset(atUnixSeconds: wall - secondsPerDay)
    let offsetAfter = offset(atUnixSeconds: wall + secondsPerDay)
    for candidate in [wall - max(offsetBefore, offsetAfter), wall - min(offsetBefore, offsetAfter)]
    where offset(atUnixSeconds: candidate) == wall - candidate {
      return (candidate, false)
    }
    return (wall - offsetBefore, true)
  }

  /// The instant the spring-forward gap holding `wall` ends. Read at the later offset, `wall`
  /// is before it; read at the earlier, at or after it. Offsets change on whole seconds, so a
  /// binary search over that bracket finds it.
  private func gapEnd(wall: Int64, offsetBefore: Int64, offsetAfter: Int64) -> Int64 {
    var low = wall - offsetAfter
    var high = wall - offsetBefore
    while high - low > 1 {
      let middle = low + (high - low) / 2
      if offset(atUnixSeconds: middle) == offsetAfter {
        high = middle
      } else {
        low = middle
      }
    }
    return high
  }
}
