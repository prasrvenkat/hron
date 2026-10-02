import Foundation
import Hron

struct Case: Decodable {
  let id: String
  let op: String
  let expr: String
  let now: String?
  let datetime: String?
  let from: String?
  let to: String?
  let n: Int?
}

/// The instant a spec timestamp names, read from its date, time and offset; the zone in
/// brackets does not change it.
func instant(_ text: String?) -> Date {
  guard let text, let open = text.firstIndex(of: "["),
    let sign = text[..<open].lastIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" })
  else { fatalError("bad timestamp \(String(describing: text))") }
  let wall = text[..<sign]
  let date = wall.prefix(10).split(separator: "-").compactMap { Int($0) }
  let time = wall.dropFirst(11).split(separator: ":")
  let offset = text[text.index(after: sign)..<open].split(separator: ":").compactMap { Int($0) }
  guard date.count == 3, time.count == 3, let hour = Int(time[0]), let minute = Int(time[1]),
    let second = Double(time[2])
  else { fatalError("bad timestamp \(text)") }
  let offsetMagnitude = offset.enumerated().reduce(0) {
    $0 + $1.element * [3600, 60, 1][$1.offset]
  }
  let offsetSeconds = text[sign] == "-" ? -offsetMagnitude : offsetMagnitude
  let local = daysFromCivil(date[0], date[1], date[2]) * 86_400 + hour * 3600 + minute * 60
  let unix = local - offsetSeconds - Int(Date.timeIntervalBetween1970AndReferenceDate)
  return Date(timeIntervalSinceReferenceDate: Double(unix) + second)
}

func format(_ date: Date, _ schedule: Schedule) -> String {
  let offset = schedule.timeZone.secondsFromGMT(for: date)
  let unix =
    Int(date.timeIntervalSinceReferenceDate.rounded(.down))
    + Int(Date.timeIntervalBetween1970AndReferenceDate)
  let local = unix + offset
  let days = (local - ((local % 86_400) + 86_400) % 86_400) / 86_400
  let second = local - days * 86_400
  let (year, month, day) = civilFromDays(days)
  var zone = (offset < 0 ? "-" : "+") + "\(two(abs(offset) / 3600)):\(two(abs(offset) / 60 % 60))"
  if offset % 60 != 0 {
    zone += ":\(two(abs(offset) % 60))"
  }
  let yearText = String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year)
  return "\(yearText)-\(two(month))-\(two(day))T\(two(second / 3600)):\(two(second / 60 % 60)):"
    + "\(two(second % 60))\(zone)[\(schedule.timeZoneIdentifier ?? "UTC")]"
}

func two(_ value: Int) -> String {
  value < 10 ? "0\(value)" : "\(value)"
}

func floorDivide(_ a: Int, _ b: Int) -> Int {
  (a - ((a % b) + b) % b) / b
}

func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
  let y = month <= 2 ? year - 1 : year
  let era = floorDivide(y, 400)
  let yearOfEra = y - era * 400
  let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
  return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
}

func civilFromDays(_ days: Int) -> (Int, Int, Int) {
  let z = days + 719_468
  let era = floorDivide(z, 146_097)
  let dayOfEra = z - era * 146_097
  let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
  let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
  let mp = (5 * dayOfYear + 2) / 153
  let month = mp < 10 ? mp + 3 : mp - 9
  return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * mp + 2) / 5 + 1)
}

func evaluate(_ c: Case) throws(HronError) -> Any {
  if c.op == "fromCron" {
    return try Schedule.fromCron(c.expr).description
  }
  let schedule = try Schedule.parse(c.expr)
  let formatted = { (date: Date?) -> Any in date.map { format($0, schedule) } ?? NSNull() }
  let all = { (dates: [Date]) -> Any in dates.map { format($0, schedule) } }
  switch c.op {
  case "parse": return schedule.description
  case "toCron": return try schedule.toCron()
  case "next": return formatted(schedule.next(after: instant(c.now)))
  case "prev": return formatted(schedule.previous(before: instant(c.now)))
  case "nextN": return all(schedule.next(c.n ?? 0, after: instant(c.now)))
  case "matches": return schedule.matches(instant(c.datetime))
  case "between":
    return all(Array(schedule.occurrences(after: instant(c.from), through: instant(c.to))))
  case "occurrences":
    return all(Array(schedule.occurrences(after: instant(c.from)).prefix(max(c.n ?? 0, 0))))
  default: fatalError("unknown op \(c.op)")
  }
}

func details(_ error: HronError) -> [String: Any] {
  let kind =
    switch error.kind {
    case .lex: "lex"
    case .parse: "parse"
    case .eval: "eval"
    case .cron: "cron"
    }
  return [
    "kind": kind,
    "message": error.message,
    "span": error.span.map { [$0.start, $0.end] } ?? NSNull(),
    "suggestion": error.suggestion ?? NSNull(),
  ]
}

let clock = ContinuousClock()
while let line = readLine() {
  guard let c = try? JSONDecoder().decode(Case.self, from: Data(line.utf8)) else {
    fatalError("not a case: \(line)")
  }
  let start = clock.now
  var outcome: [String: Any]
  do {
    outcome = ["ok": true, "result": try evaluate(c)]
  } catch {
    outcome = ["ok": false, "error": details(error)]
  }
  let elapsed = clock.now - start
  outcome["id"] = c.id
  outcome["micros"] =
    elapsed.components.seconds * 1_000_000
    + elapsed.components.attoseconds / 1_000_000_000_000
  let data = try JSONSerialization.data(withJSONObject: outcome, options: [.fragmentsAllowed])
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}
