#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum DateSpec: Hashable, Sendable {
  /// This month and day in every year.
  case named(month: MonthName, day: Int)
  /// Only this date, written `YYYY-MM-DD`.
  case iso(String)
}
