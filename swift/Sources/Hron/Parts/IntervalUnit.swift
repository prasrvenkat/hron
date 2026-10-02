#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum IntervalUnit: Hashable, Sendable {
  case minutes, hours
}
