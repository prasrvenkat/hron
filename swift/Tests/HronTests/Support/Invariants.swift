import Foundation
import Hron

/// The rules of spec/README.md, "Invariants". Two timestamps are equal when they are the same
/// instant, which is what `Date`'s `==` compares.
struct Invariants {
  let schedule: Schedule
  let now: Date
  let count: Int
  let nextN: [Date]

  init(schedule: Schedule, now: Date, count: Int) {
    self.schedule = schedule
    self.now = now
    self.count = count
    nextN = schedule.next(count, after: now)
  }

  /// Nil when the rule holds; a rule this runner does not know fails.
  func failure(of rule: String) -> String? {
    switch rule {
    case "next_matches": nextMatches()
    case "next_after_now": nextAfterNow()
    case "next_n_chain": nextNChain()
    case "occurrences_prefix": occurrencesPrefix()
    case "between_window": betweenWindow()
    case "prev_inverse": previousInverse()
    case "prev_before_now": previousBeforeNow()
    case "display_roundtrip": displayRoundtrip()
    default: "rule is not implemented by this runner"
    }
  }

  private func nextMatches() -> String? {
    guard let next = schedule.next(after: now), !schedule.matches(next) else { return nil }
    return "matches(\(next)) is false"
  }

  private func nextAfterNow() -> String? {
    guard let next = schedule.next(after: now), next <= now else { return nil }
    return "nextFrom(now) is \(next), not after now"
  }

  private func nextNChain() -> String? {
    if zip(nextN, nextN.dropFirst()).contains(where: { $0 >= $1 }) {
      return "not strictly increasing: \(nextN)"
    }
    if nextN.isEmpty && schedule.next(after: now) != nil {
      return "next_n is empty but nextFrom(now) is not null"
    }
    var cursor = now
    for (i, got) in nextN.enumerated() {
      let expected = schedule.next(after: cursor)
      if expected != got {
        return "next_n[\(i)] is \(got), but nextFrom(\(cursor)) is \(String(describing: expected))"
      }
      cursor = got
    }
    return nil
  }

  private func occurrencesPrefix() -> String? {
    let taken = Array(schedule.occurrences(after: now).prefix(count))
    return taken == nextN ? nil : "occurrences \(taken) vs next_n \(nextN)"
  }

  private func betweenWindow() -> String? {
    guard let last = nextN.last else { return nil }
    let got = Array(schedule.occurrences(after: now, through: last))
    return got == nextN ? nil : "between \(got) vs next_n \(nextN)"
  }

  private func previousInverse() -> String? {
    for (a, b) in zip(nextN, nextN.dropFirst()) {
      let got = schedule.previous(before: b)
      if got != a {
        return "previousFrom(\(b)) is \(String(describing: got)), expected \(a)"
      }
    }
    return nil
  }

  private func previousBeforeNow() -> String? {
    guard let previous = schedule.previous(before: now) else { return nil }
    if previous >= now {
      return "previousFrom(now) is \(previous), not before now"
    }
    if !schedule.matches(previous) {
      return "matches(\(previous)) is false"
    }
    if let next = schedule.next(after: previous), next < now {
      return "nextFrom(\(previous)) is \(next), an occurrence between previousFrom(now) and now"
    }
    return nil
  }

  private func displayRoundtrip() -> String? {
    let display = schedule.description
    guard let again = try? Schedule.parse(display).description else {
      return "re-parse of '\(display)' failed"
    }
    return again == display ? nil : "'\(display)' re-displays as '\(again)'"
  }
}
