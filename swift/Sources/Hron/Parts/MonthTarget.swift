#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum MonthTarget: Hashable, Sendable {
  case days([DayOfMonthSpec])
  case lastDay
  case lastWeekday
  /// Without a direction the weekday stays within the month, as cron's `W` does; with one it
  /// can cross into the adjacent month.
  case nearestWeekday(day: Int, direction: NearestDirection?)
  case ordinalWeekday(ordinal: OrdinalPosition, weekday: Weekday)
}
