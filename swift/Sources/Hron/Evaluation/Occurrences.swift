import Foundation

/// A schedule's occurrences after an instant, in order, each found only when it is reached.
///
/// Without an end it stops only at an `until` clause or the end of the supported range, so
/// take a prefix of it; `map`, `filter` and `prefix` on it stay lazy.
public struct Occurrences: LazySequenceProtocol, Sendable {
  let search: Search
  /// Nil when no occurrence can follow, as when `start` or `end` is outside the supported range.
  let start: Moment?
  let end: Moment?

  public func makeIterator() -> Iterator {
    Iterator(search: search, current: start, end: end)
  }

  public struct Iterator: IteratorProtocol, Sendable {
    let search: Search
    var current: Moment?
    let end: Moment?

    public mutating func next() -> Date? {
      guard let now = current, let next = search.nearest(now, .forward),
        end.map({ !$0.isBefore(next) }) ?? true
      else {
        current = nil
        return nil
      }
      current = Moment(seconds: next)
      return date(fromUnixSeconds: next)
    }
  }
}
