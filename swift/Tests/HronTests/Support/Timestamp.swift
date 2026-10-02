import Foundation

/// Reads and writes the spec's timestamps, `2026-02-06T09:00:00-05:00[America/New_York]`, with
/// proleptic Gregorian arithmetic, as Foundation's calendar is Julian before 1582.
enum Timestamp {
  struct Parsed {
    let date: Date
    let offset: Int64
    let zone: String
  }

  static func parse(_ text: String) -> Parsed? {
    let scalars = Array(text.unicodeScalars)
    guard let open = scalars.firstIndex(of: "["), scalars.last == "]" else { return nil }
    let zone = String(String.UnicodeScalarView(scalars[(open + 1)..<(scalars.count - 1)]))
    let stamp = String(String.UnicodeScalarView(scalars[..<open]))
    guard let sign = stamp.lastIndex(where: { $0 == "+" || $0 == "-" }),
      stamp.distance(from: stamp.startIndex, to: sign) >= 19
    else { return nil }
    let wall = stamp[..<sign]
    let offsetParts = stamp[stamp.index(after: sign)...].split(separator: ":").compactMap {
      Int64($0)
    }
    let wallParts = wall.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int64($0) }
    guard wallParts.count == 6, (2...3).contains(offsetParts.count) else { return nil }
    let offsetMagnitude =
      offsetParts[0] * 3600 + offsetParts[1] * 60 + (offsetParts.count == 3 ? offsetParts[2] : 0)
    let offset = stamp[sign] == "-" ? -offsetMagnitude : offsetMagnitude
    let days = daysFromCivil(year: wallParts[0], month: wallParts[1], day: wallParts[2])
    let local = days * 86_400 + wallParts[3] * 3600 + wallParts[4] * 60 + wallParts[5]
    return Parsed(date: unixDate(local - offset), offset: offset, zone: zone)
  }

  static func date(_ text: String) -> Date {
    guard let parsed = parse(text) else { fatalError("bad timestamp '\(text)'") }
    return parsed.date
  }

  static func format(_ date: Date, in zone: TimeZone, named name: String) -> String {
    let offset = Int64(zone.secondsFromGMT(for: date))
    let local = unixSeconds(date) + offset
    let (days, second) = (floorDiv(local, 86_400), local - floorDiv(local, 86_400) * 86_400)
    let (year, month, day) = civilFromDays(days)
    let sign = offset < 0 ? "-" : "+"
    let magnitude = abs(offset)
    var offsetText = "\(sign)\(two(magnitude / 3600)):\(two(magnitude / 60 % 60))"
    if magnitude % 60 != 0 {
      offsetText += ":\(two(magnitude % 60))"
    }
    let yearText = String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year)
    return "\(yearText)-\(two(month))-\(two(day))T\(two(second / 3600)):\(two(second / 60 % 60))"
      + ":\(two(second % 60))\(offsetText)[\(name)]"
  }

  static func wallDate(_ date: Date, in zone: TimeZone) -> String {
    String(format(date, in: zone, named: "").prefix(10))
  }

  static func unixSeconds(_ date: Date) -> Int64 {
    Int64(date.timeIntervalSinceReferenceDate.rounded(.down))
      + Int64(Date.timeIntervalBetween1970AndReferenceDate)
  }

  static func unixDate(_ seconds: Int64) -> Date {
    Date(
      timeIntervalSinceReferenceDate: Double(
        seconds - Int64(Date.timeIntervalBetween1970AndReferenceDate)))
  }

  private static func two(_ value: Int64) -> String {
    value < 10 ? "0\(value)" : "\(value)"
  }

  private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    a >= 0 ? a / b : -((-a + b - 1) / b)
  }

  static func daysFromCivil(year: Int64, month: Int64, day: Int64) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = floorDiv(y, 400)
    let yearOfEra = y - era * 400
    let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
    return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
  }

  static func civilFromDays(_ days: Int64) -> (Int64, Int64, Int64) {
    let z = days + 719_468
    let era = floorDiv(z, 146_097)
    let dayOfEra = z - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let mp = (5 * dayOfYear + 2) / 153
    let month = mp < 10 ? mp + 3 : mp - 9
    return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * mp + 2) / 5 + 1)
  }
}
