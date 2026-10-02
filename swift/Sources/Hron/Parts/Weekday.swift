public enum Weekday: Hashable, Sendable, CaseIterable {
  case monday, tuesday, wednesday, thursday, friday, saturday, sunday

  var name: String {
    switch self {
    case .monday: "monday"
    case .tuesday: "tuesday"
    case .wednesday: "wednesday"
    case .thursday: "thursday"
    case .friday: "friday"
    case .saturday: "saturday"
    case .sunday: "sunday"
    }
  }

  var isoNumber: Int {
    switch self {
    case .monday: 1
    case .tuesday: 2
    case .wednesday: 3
    case .thursday: 4
    case .friday: 5
    case .saturday: 6
    case .sunday: 7
    }
  }

  init?(word: String) {
    switch word {
    case "monday", "mon": self = .monday
    case "tuesday", "tue": self = .tuesday
    case "wednesday", "wed": self = .wednesday
    case "thursday", "thu": self = .thursday
    case "friday", "fri": self = .friday
    case "saturday", "sat": self = .saturday
    case "sunday", "sun": self = .sunday
    default: return nil
    }
  }

  var isWeekend: Bool { self == .saturday || self == .sunday }
}
