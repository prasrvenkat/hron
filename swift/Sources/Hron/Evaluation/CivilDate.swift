/// A date in the proleptic Gregorian calendar. Foundation's `Calendar` switches to the Julian
/// calendar before 1582, so hron counts days itself.
struct CivilDate: Hashable, Comparable, Sendable {
  let year: Int
  let month: Int
  let day: Int

  /// Every supported instant has its local date in years 1 to 9999 in every zone
  /// (spec/README.md, "Supported range"), but an occurrence can be scheduled in year 0 and land
  /// in year 1, as the next nearest weekday to Dec 31 of year 0 does.
  static let years = 0...9999

  static let epoch = CivilDate(checkedYear: 1970, month: 1, day: 1)

  /// The first Monday after the epoch, where week intervals align by default (spec/README.md,
  /// "WeekRepeat epoch alignment").
  static let epochMonday = CivilDate(checkedYear: 1970, month: 1, day: 5)

  private static let daysRange =
    CivilDate(checkedYear: years.lowerBound, month: 1, day: 1)
    .daysSinceEpoch...CivilDate(checkedYear: years.upperBound, month: 12, day: 31).daysSinceEpoch

  private init(checkedYear year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  init?(year: Int, month: Int, day: Int) {
    guard Self.years.contains(year), (1...12).contains(month),
      (1...Self.daysIn(month: month, year: year)).contains(day)
    else { return nil }
    self.init(checkedYear: year, month: month, day: day)
  }

  /// Howard Hinnant's civil_from_days. Once the range is checked, every value fits an `Int`.
  init?(daysSinceEpoch days: Int64) {
    guard Self.daysRange.contains(days) else { return nil }
    let shifted = Int(days) + 719_468
    let era = floorDivide(shifted, 146_097)
    let dayOfEra = shifted - era * 146_097
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    self.init(
      checkedYear: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month,
      day: dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
  }

  /// A written date starts at 0001-01-01, though `years` starts at year 0 for dates computed
  /// from others.
  init?(iso text: String) {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard text.utf8.count == 10, parts.map(\.utf8.count) == [4, 2, 2],
      parts.allSatisfy({
        $0.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
      }),
      let year = Int(parts[0]), year >= 1, let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    self.init(year: year, month: month, day: day)
  }

  static func daysIn(month: Int, year: Int) -> Int {
    switch month {
    case 2: isLeapYear(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  static func isLeapYear(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  /// Howard Hinnant's days_from_civil: days since 1970-01-01.
  var daysSinceEpoch: Int64 {
    let marchYear = month <= 2 ? year - 1 : year
    let era = floorDivide(marchYear, 400)
    let yearOfEra = marchYear - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return Int64(era * 146_097 + dayOfEra - 719_468)
  }

  var weekday: Weekday {
    // 1970-01-01 was a Thursday.
    Weekday.allCases[Int(floorModulo(daysSinceEpoch + 3, 7))]
  }

  var monthName: MonthName { MonthName.allCases[month - 1] }

  var iso: String {
    func padded(_ value: Int, _ width: Int) -> String {
      let digits = String(value)
      return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }
    return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
  }

  var lastOfMonth: CivilDate {
    CivilDate(checkedYear: year, month: month, day: Self.daysIn(month: month, year: year))
  }

  var monthIndex: Int64 { Int64(year * 12 + month - 1) }

  init?(firstOfMonthIndex index: Int64) {
    guard let year = Int(exactly: floorDivide(index, 12)) else { return nil }
    self.init(year: year, month: Int(floorModulo(index, 12)) + 1, day: 1)
  }

  init?(firstOfYear year: Int64) {
    guard let year = Int(exactly: year) else { return nil }
    self.init(year: year, month: 1, day: 1)
  }

  func adding(days: Int64) -> CivilDate? {
    let (sum, overflow) = daysSinceEpoch.addingReportingOverflow(days)
    return overflow ? nil : CivilDate(daysSinceEpoch: sum)
  }

  func days(until other: CivilDate) -> Int64 {
    other.daysSinceEpoch - daysSinceEpoch
  }

  static func < (a: CivilDate, b: CivilDate) -> Bool {
    (a.year, a.month, a.day) < (b.year, b.month, b.day)
  }
}
