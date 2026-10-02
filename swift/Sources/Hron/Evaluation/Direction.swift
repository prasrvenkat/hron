enum Direction {
  case forward, backward

  var sign: Int64 {
    switch self {
    case .forward: 1
    case .backward: -1
    }
  }

  func precedes(_ a: Int64, _ b: Int64) -> Bool {
    switch self {
    case .forward: a < b
    case .backward: a > b
    }
  }

  func lies(_ instant: Int64, beyond now: Moment) -> Bool {
    switch self {
    case .forward: now.isBefore(instant)
    case .backward: now.isAfter(instant)
    }
  }
}
