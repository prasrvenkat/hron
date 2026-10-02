#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum DayFilter: Hashable, Sendable {
  case every
  case weekday
  case weekend
  case days([Weekday])
}
