import Foundation

/// An instant given to hron, as whole Unix seconds and whether a fraction of a second follows.
/// Every occurrence falls on a whole second, so this compares with them exactly.
struct Moment: Sendable {
  let seconds: Int64
  let hasFraction: Bool

  /// spec/README.md, "Supported range": from 0001-01-02T00:00:00Z up to 9999-12-30T00:00:00Z.
  static let supportedSeconds: Range<Int64> = -62_135_510_400..<253_402_128_000

  static let referenceDateSeconds = Int64(Date.timeIntervalBetween1970AndReferenceDate)

  init(seconds: Int64, hasFraction: Bool = false) {
    self.seconds = seconds
    self.hasFraction = hasFraction
  }

  /// Nil outside the supported range, which holds no NaN or infinite date. The range is checked
  /// before converting, as `Int64(_:)` traps on a value it cannot hold.
  init?(_ date: Date) {
    // Read from the reference date, which is what `Date` stores, so no rounding moves the
    // instant across a whole second.
    let sinceReference = date.timeIntervalSinceReferenceDate
    let range = Self.supportedSeconds
    guard sinceReference.isFinite,
      sinceReference >= Double(range.lowerBound - Self.referenceDateSeconds),
      sinceReference < Double(range.upperBound - Self.referenceDateSeconds)
    else { return nil }
    let whole = sinceReference.rounded(.down)
    self.init(
      seconds: Int64(whole) + Self.referenceDateSeconds, hasFraction: whole != sinceReference)
  }

  func isBefore(_ instant: Int64) -> Bool { seconds < instant }

  func isAfter(_ instant: Int64) -> Bool { hasFraction ? seconds >= instant : seconds > instant }
}

let secondsPerDay: Int64 = 86_400

func date(fromUnixSeconds seconds: Int64) -> Date {
  Date(timeIntervalSinceReferenceDate: Double(seconds - Moment.referenceDateSeconds))
}
