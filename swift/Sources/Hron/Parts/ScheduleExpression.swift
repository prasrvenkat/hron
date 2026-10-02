#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum ScheduleExpression: Hashable, Sendable {
  /// Slots `from`, `from + interval`, ... through `to`, on the days of `dayFilter`, or every day
  /// when it is `nil`.
  case intervalRepeat(
    interval: Int, unit: IntervalUnit, from: TimeOfDay, to: TimeOfDay, dayFilter: DayFilter?)
  /// `days` is `.every` whenever `interval` is above 1.
  case dayRepeat(interval: Int, days: DayFilter, times: [TimeOfDay])
  case weekRepeat(interval: Int, days: [Weekday], times: [TimeOfDay])
  case monthRepeat(interval: Int, target: MonthTarget, times: [TimeOfDay])
  case singleDate(date: DateSpec, times: [TimeOfDay])
  case yearRepeat(interval: Int, target: YearTarget, times: [TimeOfDay])
}
