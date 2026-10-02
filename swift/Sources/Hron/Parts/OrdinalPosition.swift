#if hasAttribute(nonexhaustive)
  @nonexhaustive
#endif
public enum OrdinalPosition: Hashable, Sendable {
  case first, second, third, fourth, fifth, last

  var name: String {
    switch self {
    case .first: "first"
    case .second: "second"
    case .third: "third"
    case .fourth: "fourth"
    case .fifth: "fifth"
    case .last: "last"
    }
  }
}
