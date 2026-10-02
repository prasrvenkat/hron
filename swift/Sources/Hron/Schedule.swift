import Foundation

/// Every timestamp is a `Date`, an instant with no zone. A schedule computes in ``timeZone``,
/// so format its results in that zone to show the wall-clock times it fires at.
public struct Schedule: Hashable, Sendable {
  public let expression: ScheduleExpression
  /// The IANA name in the database's capitalization, or `nil` when the schedule names no zone.
  public let timeZoneIdentifier: String?
  /// The zone occurrences are computed in: the named one, or UTC without one.
  public let timeZone: TimeZone
  /// Empty without an `except` clause.
  public let except: [Exception]
  public let until: UntilSpec?
  let startingDate: CivilDate?
  /// Empty without a `during` clause.
  public let during: [MonthName]

  init(
    expression: ScheduleExpression, zone: IANATimeZone?, except: [Exception], until: UntilSpec?,
    starting: CivilDate?, during: [MonthName]
  ) {
    self.expression = expression
    timeZoneIdentifier = zone?.identifier
    timeZone = zone?.timeZone ?? IANATimeZone.utc
    self.except = except
    self.until = until
    startingDate = starting
    self.during = during
  }

  /// Throws a `lex` or `parse` error for any input that is not a valid expression.
  public static func parse(_ input: String) throws(HronError) -> Schedule {
    try Parser.parse(input)
  }

  /// Whether `parse` accepts `input`.
  public static func validate(_ input: String) -> Bool {
    (try? parse(input)) != nil
  }

  /// The schedule that fires at the same times as a 5-field cron expression. Throws a `cron`
  /// error when the input is not valid cron or has no exact hron equivalent.
  public static func fromCron(_ cronExpr: String) throws(HronError) -> Schedule {
    try schedule(fromCron: cronExpr)
  }

  /// The 5-field cron expression that fires at the same local times. Throws a `cron` error when
  /// cron cannot. The timezone is not part of it: run it on a clock in ``timeZone``.
  public func toCron() throws(HronError) -> String {
    try cronExpression(for: self)
  }

  /// The first occurrence strictly after `now`; `nil` when there is none, or when `now` or the
  /// occurrence is outside the supported range, 0001-01-02T00:00:00Z up to 9999-12-30T00:00:00Z.
  public func next(after now: Date) -> Date? {
    Moment(now).flatMap { Search(self).nearest($0, .forward) }.map(date(fromUnixSeconds:))
  }

  /// Up to `n` occurrences strictly after `now`, in order; empty when `n <= 0`.
  public func next(_ n: Int, after now: Date) -> [Date] {
    guard n > 0 else { return [] }
    return Array(occurrences(after: now).prefix(n))
  }

  /// The last occurrence strictly before `now`; `nil` when there is none in the supported range.
  public func previous(before now: Date) -> Date? {
    Moment(now).flatMap { Search(self).nearest($0, .backward) }.map(date(fromUnixSeconds:))
  }

  /// Whether the minute containing `datetime`, on the schedule's wall clock, is an occurrence:
  /// 09:00:30 matches `every day at 09:00`. False outside the supported range.
  public func matches(_ datetime: Date) -> Bool {
    Moment(datetime).map { Search(self).matches($0) } ?? false
  }

  /// The occurrences strictly after `from`, lazily, through an `until` clause or the end of the
  /// supported range.
  public func occurrences(after from: Date) -> Occurrences {
    Occurrences(search: Search(self), start: Moment(from), end: nil)
  }

  /// The occurrences `t` with `from < t <= to`, lazily.
  public func occurrences(after from: Date, through to: Date) -> Occurrences {
    let end = Moment(to)
    return Occurrences(search: Search(self), start: end == nil ? nil : Moment(from), end: end)
  }

  /// The start date of a `starting` clause, as `YYYY-MM-DD`.
  public var starting: String? { startingDate?.iso }

  /// Equal parts (spec/README.md, "Equality"): lists compare in order, duplicates included.
  public static func == (a: Schedule, b: Schedule) -> Bool {
    a.expression == b.expression && a.timeZoneIdentifier == b.timeZoneIdentifier
      && a.except == b.except && a.until == b.until && a.startingDate == b.startingDate
      && a.during == b.during
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(expression)
    hasher.combine(timeZoneIdentifier)
    hasher.combine(except)
    hasher.combine(until)
    hasher.combine(startingDate)
    hasher.combine(during)
  }
}
