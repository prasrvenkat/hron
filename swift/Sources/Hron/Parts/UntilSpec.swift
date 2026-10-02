#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum UntilSpec: Hashable, Sendable {
  /// Written `YYYY-MM-DD`.
  case iso(String)
  /// The first such date on or after the schedule's `starting` date.
  case named(month: MonthName, day: Int)
}
