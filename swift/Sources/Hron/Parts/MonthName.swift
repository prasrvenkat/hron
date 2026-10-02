public enum MonthName: Hashable, Sendable, CaseIterable {
  case january, february, march, april, may, june
  case july, august, september, october, november, december

  var shortName: String {
    switch self {
    case .january: "jan"
    case .february: "feb"
    case .march: "mar"
    case .april: "apr"
    case .may: "may"
    case .june: "jun"
    case .july: "jul"
    case .august: "aug"
    case .september: "sep"
    case .october: "oct"
    case .november: "nov"
    case .december: "dec"
    }
  }

  var number: Int {
    switch self {
    case .january: 1
    case .february: 2
    case .march: 3
    case .april: 4
    case .may: 5
    case .june: 6
    case .july: 7
    case .august: 8
    case .september: 9
    case .october: 10
    case .november: 11
    case .december: 12
    }
  }

  /// February counts 29, as its day can name Feb 29.
  var maxDay: Int {
    switch self {
    case .february: 29
    case .april, .june, .september, .november: 30
    default: 31
    }
  }

  init?(word: String) {
    switch word {
    case "january", "jan": self = .january
    case "february", "feb": self = .february
    case "march", "mar": self = .march
    case "april", "apr": self = .april
    case "may": self = .may
    case "june", "jun": self = .june
    case "july", "jul": self = .july
    case "august", "aug": self = .august
    case "september", "sep": self = .september
    case "october", "oct": self = .october
    case "november", "nov": self = .november
    case "december", "dec": self = .december
    default: return nil
    }
  }

  init?(number: Int) {
    guard (1...12).contains(number) else { return nil }
    self = Self.allCases[number - 1]
  }
}
