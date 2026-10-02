#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum NearestDirection: Hashable, Sendable {
  case next, previous
}
