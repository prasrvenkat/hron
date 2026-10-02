#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum YearTarget: Hashable, Sendable {
  /// Written `dec 25`.
  case date(month: MonthName, day: Int)
  case ordinalWeekday(ordinal: OrdinalPosition, weekday: Weekday, month: MonthName)
  /// Written `the 25th of dec`.
  case dayOfMonth(day: Int, month: MonthName)
  case lastWeekday(month: MonthName)
}
