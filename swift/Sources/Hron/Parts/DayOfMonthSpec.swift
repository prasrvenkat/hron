#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum DayOfMonthSpec: Hashable, Sendable {
  case single(Int)
  /// From `start` through `end`, both included.
  case range(start: Int, end: Int)
}
