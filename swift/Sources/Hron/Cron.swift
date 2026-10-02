/// Cron text as UTF-8. Its syntax is ASCII, so splitting at ASCII bytes keeps every slice valid
/// UTF-8, and no other character can compare equal to an ASCII one, as it can in `String`.
private typealias CronText = ArraySlice<UInt8>

private let maxListedTimes = 24
private let bothDaysRestricted =
  "not expressible in hron: cron fires on either the day of month or the day of week"
private let intervalDays =
  "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days"

/// Digit strings may be of any length. Every number at or above this cap is out of every field's
/// range and steps past every range's end, so saturating at it keeps each comparison exact.
private let numberCap = 1000

/// Cron numbers the days of the week from Sunday, 0.
private let cronWeekdays: [Weekday] = [
  .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday,
]
private let cronOrdinals: [OrdinalPosition] = [.first, .second, .third, .fourth, .fifth]

private enum Field {
  case minute, hour, dayOfMonth, month, dayOfWeek

  var name: String {
    switch self {
    case .minute: "minute"
    case .hour: "hour"
    case .dayOfMonth: "day of month"
    case .month: "month"
    case .dayOfWeek: "day of week"
    }
  }

  var min: Int {
    switch self {
    case .minute, .hour, .dayOfWeek: 0
    case .dayOfMonth, .month: 1
    }
  }

  var max: Int {
    switch self {
    case .minute: 59
    case .hour: 23
    case .dayOfMonth: 31
    case .month: 12
    case .dayOfWeek: 7
    }
  }

  /// In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
  var starEnd: Int { self == .dayOfWeek ? 6 : max }

  var names: [String] {
    switch self {
    case .month: MonthName.allCases.map(\.shortName)
    case .dayOfWeek: cronWeekdays.map { String($0.name.prefix(3)) }
    case .minute, .hour, .dayOfMonth: []
    }
  }
}

private enum Bounds {
  case star
  case value(CronText)
  case range(CronText, CronText)
}

private struct Item {
  let bounds: Bounds
  let step: CronText?
}

private enum MonthDays {
  case any
  case days([Int])
  case last
  case lastWeekday
  case nearest(Int)
}

private enum WeekDays {
  case any
  case days([Int])
  case nth(Weekday, Int)
  case last(Weekday)
}

private enum Days {
  case ofWeek(DayFilter)
  case ofMonth(MonthTarget)
}

/// spec/README.md, "fromCron".
func schedule(fromCron input: String) throws(HronError) -> Schedule {
  let whitespace = [" ", "\t", "\r", "\n"].map { UInt8(ascii: $0) }
  var text = CronText(input.utf8)
  while let first = text.first, whitespace.contains(first) { text.removeFirst() }
  while let last = text.last, whitespace.contains(last) { text.removeLast() }
  if text.first == UInt8(ascii: "@") {
    text = try shortcut(text)
  }
  let fields = text.split { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
  guard fields.count == 5 else {
    throw .cron("expected 5 cron fields, got \(fields.count)")
  }

  let minutes = try values(fields[0], .minute).sorted()
  let hours = try values(fields[1], .hour).sorted()
  let monthDays = try parseDayOfMonth(fields[2])
  let months = try values(fields[3], .month).sorted()
  let weekDays = try parseDayOfWeek(fields[4])
  let days = try dayExpression(monthDays, weekDays)
  let times = hours.flatMap { hour in minutes.map { TimeOfDay(hour: hour, minute: $0) } }

  let gap = equalGap(times)
  let expression: ScheduleExpression
  if case .ofWeek(let filter) = days, let gap {
    expression = interval(times, gap: gap, days: filter)
  } else if times.count > maxListedTimes {
    throw gap == nil
      ? .cron("not expressible in hron: \(times.count) times a day are too many to list")
      : .cron(intervalDays)
  } else if let target = yearTarget(days, months: months) {
    expression = .yearRepeat(interval: 1, target: target, times: times)
  } else {
    switch days {
    case .ofWeek(let filter): expression = .dayRepeat(interval: 1, days: filter, times: times)
    case .ofMonth(let target): expression = .monthRepeat(interval: 1, target: target, times: times)
    }
  }
  let isYearly = if case .yearRepeat = expression { true } else { false }
  let during = isYearly || months.count == 12 ? [] : months.compactMap(MonthName.init(number:))
  return Schedule(
    expression: expression, zone: nil, except: [], until: nil, starting: nil, during: during)
}

private func shortcut(_ text: CronText) throws(HronError) -> CronText {
  let expanded: String
  switch String(decoding: text.map(asciiLowercased), as: UTF8.self) {
  case "@yearly", "@annually": expanded = "0 0 1 1 *"
  case "@monthly": expanded = "0 0 1 * *"
  case "@weekly": expanded = "0 0 * * 0"
  case "@daily", "@midnight": expanded = "0 0 * * *"
  case "@hourly": expanded = "0 * * * *"
  default: throw .cron("unknown cron shortcut: \(string(text))")
  }
  return CronText(expanded.utf8)
}

private func parseDayOfMonth(_ text: CronText) throws(HronError) -> MonthDays {
  if isAny(text) {
    return .any
  }
  if equalsIgnoringCase(text, "L") {
    return .last
  }
  if equalsIgnoringCase(text, "LW") {
    return .lastWeekday
  }
  if let day = dropSuffix(text, UInt8(ascii: "W")), isNumber(day) {
    return .nearest(try fieldValue(day, .dayOfMonth))
  }
  return .days(try values(text, .dayOfMonth))
}

private func parseDayOfWeek(_ text: CronText) throws(HronError) -> WeekDays {
  let field = Field.dayOfWeek
  if isAny(text) {
    return .any
  }
  if let hash = text.firstIndex(of: UInt8(ascii: "#")) {
    let day = text[..<hash]
    let nth = text[(hash + 1)...]
    if isValue(day, field), isNumber(nth) {
      let weekday = cronWeekdays[try fieldValue(day, field) % 7]
      let n = number(nth)
      guard (1...5).contains(n) else {
        throw .cron("day of week ordinal must be 1-5, got \(string(nth))")
      }
      return .nth(weekday, n)
    }
  }
  if let day = dropSuffix(text, UInt8(ascii: "L")), isValue(day, field) {
    return .last(cronWeekdays[try fieldValue(day, field) % 7])
  }
  return .days(try values(text, field))
}

/// In the order of first appearance, in which fromCron lists days of the week.
private func values(_ text: CronText, _ field: Field) throws(HronError) -> [Int] {
  guard let items = items(text, field) else {
    throw .cron("invalid \(field.name): \(string(text))")
  }
  var values: [Int] = []
  for item in items {
    let first: Int
    let last: Int
    switch item.bounds {
    case .star:
      (first, last) = (field.min, field.starEnd)
    case .value(let a):
      first = try fieldValue(a, field)
      // `7/n` starts past the end of `*`, so it is Sunday alone.
      last = item.step == nil ? first : max(first, field.starEnd)
    case .range(let a, let b):
      (first, last) = (try fieldValue(a, field), try fieldValue(b, field))
      guard first <= last else {
        throw .cron("\(field.name) range must not run backwards: \(string(a))-\(string(b))")
      }
    }
    let step = item.step.map(number) ?? 1
    guard step > 0 else {
      throw .cron("\(field.name) step must be at least 1")
    }
    for value in stride(from: first, through: last, by: step) {
      let value = field == .dayOfWeek ? value % 7 : value
      if !values.contains(value) {
        values.append(value)
      }
    }
  }
  return values
}

private func items(_ text: CronText, _ field: Field) -> [Item]? {
  var items: [Item] = []
  for item in text.split(separator: UInt8(ascii: ","), omittingEmptySubsequences: false) {
    let slash = item.firstIndex(of: UInt8(ascii: "/"))
    let range = slash.map { item[..<$0] } ?? item
    let step = slash.map { item[($0 + 1)...] }
    let bounds: Bounds
    if range.elementsEqual("*".utf8) {
      bounds = .star
    } else if let dash = range.firstIndex(of: UInt8(ascii: "-")) {
      bounds = .range(range[..<dash], range[(dash + 1)...])
    } else {
      bounds = .value(range)
    }
    let valid: Bool =
      switch bounds {
      case .star: true
      case .value(let a): isValue(a, field)
      case .range(let a, let b): isValue(a, field) && isValue(b, field)
      }
    guard valid, step.map(isNumber) ?? true else { return nil }
    items.append(Item(bounds: bounds, step: step))
  }
  return items
}

private func isAny(_ text: CronText) -> Bool {
  text.elementsEqual("*".utf8) || text.elementsEqual("?".utf8)
}

private func isNumber(_ text: CronText) -> Bool {
  !text.isEmpty && text.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
}

private func isValue(_ text: CronText, _ field: Field) -> Bool {
  isNumber(text) || nameValue(text, field) != nil
}

private func nameValue(_ text: CronText, _ field: Field) -> Int? {
  field.names.firstIndex { equalsIgnoringCase(text, $0) }.map { $0 + field.min }
}

private func number(_ digits: CronText) -> Int {
  digits.reduce(0) { Swift.min($0 * 10 + Int($1 - UInt8(ascii: "0")), numberCap) }
}

private func fieldValue(_ text: CronText, _ field: Field) throws(HronError) -> Int {
  let value = nameValue(text, field) ?? number(text)
  guard (field.min...field.max).contains(value) else {
    throw .cron("\(field.name) must be \(field.min)-\(field.max), got \(string(text))")
  }
  return value
}

private func equalsIgnoringCase(_ text: CronText, _ word: String) -> Bool {
  text.elementsEqual(word.utf8) { asciiLowercased($0) == asciiLowercased($1) }
}

private func dropSuffix(_ text: CronText, _ letter: UInt8) -> CronText? {
  guard let last = text.last, asciiLowercased(last) == asciiLowercased(letter) else { return nil }
  return text.dropLast()
}

private func asciiLowercased(_ byte: UInt8) -> UInt8 {
  (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
}

private func string(_ text: CronText) -> String {
  String(decoding: text, as: UTF8.self)
}

private func dayExpression(_ monthDays: MonthDays, _ weekDays: WeekDays) throws(HronError) -> Days {
  switch (monthDays, weekDays) {
  case (.any, .any):
    return .ofWeek(.every)
  case (.any, .days(let days)):
    return .ofWeek(weekdayFilter(days))
  case (.any, .nth(let weekday, let n)):
    return .ofMonth(.ordinalWeekday(ordinal: cronOrdinals[n - 1], weekday: weekday))
  case (.any, .last(let weekday)):
    return .ofMonth(.ordinalWeekday(ordinal: .last, weekday: weekday))
  case (.days(let days), .any) where days.count == 31:
    return .ofWeek(.every)
  case (.days(let days), .any):
    let specs = runs(days.sorted()).map { (first, last) -> DayOfMonthSpec in
      first == last ? .single(first) : .range(start: first, end: last)
    }
    return .ofMonth(.days(specs))
  case (.last, .any):
    return .ofMonth(.lastDay)
  case (.lastWeekday, .any):
    return .ofMonth(.lastWeekday)
  case (.nearest(let day), .any):
    return .ofMonth(.nearestWeekday(day: day, direction: nil))
  default:
    throw .cron(bothDaysRestricted)
  }
}

private func weekdayFilter(_ days: [Int]) -> DayFilter {
  switch days.sorted() {
  case [0, 1, 2, 3, 4, 5, 6]: .every
  case [1, 2, 3, 4, 5]: .weekday
  case [0, 6]: .weekend
  default: .days(days.map { cronWeekdays[$0] })
  }
}

private func equalGap(_ times: [TimeOfDay]) -> Int? {
  let minutes = times.map(\.minuteOfDay)
  guard minutes.count >= 3 else { return nil }
  let gap = minutes[1] - minutes[0]
  return zip(minutes, minutes.dropFirst()).allSatisfy { $1 - $0 == gap } ? gap : nil
}

private func interval(_ times: [TimeOfDay], gap: Int, days: DayFilter) -> ScheduleExpression {
  let from = times[0]
  let last = times[times.count - 1]
  let to =
    from.minuteOfDay == 0 && last.minuteOfDay + gap >= 24 * 60
    ? TimeOfDay(hour: 23, minute: 59) : last
  let (interval, unit): (Int, IntervalUnit) = gap % 60 == 0 ? (gap / 60, .hours) : (gap, .minutes)
  return .intervalRepeat(
    interval: interval, unit: unit, from: from, to: to, dayFilter: days == .every ? nil : days)
}

private func yearTarget(_ days: Days, months: [Int]) -> YearTarget? {
  guard case .ofMonth(let target) = days, months.count == 1,
    let month = MonthName(number: months[0])
  else { return nil }
  switch target {
  case .days(let specs):
    guard specs.count == 1, case .single(let day) = specs[0], day <= month.maxDay else {
      return nil
    }
    return .date(month: month, day: day)
  case .lastWeekday:
    return .lastWeekday(month: month)
  case .ordinalWeekday(let ordinal, let weekday):
    return .ordinalWeekday(ordinal: ordinal, weekday: weekday, month: month)
  case .lastDay, .nearestWeekday:
    return nil
  }
}

/// spec/README.md, "toCron".
func cronExpression(for schedule: Schedule) throws(HronError) -> String {
  if !schedule.except.isEmpty {
    throw notExpressible("except clauses not supported")
  }
  if schedule.until != nil {
    throw notExpressible("until clauses not supported")
  }
  if schedule.startingDate != nil {
    throw notExpressible("starting clauses not supported")
  }
  let (dayOfMonth, dayOfWeek) = try dayFields(schedule.expression)
  let month = try monthField(schedule)
  let (minute, hour) = try timeFields(schedule.expression)
  return "\(minute) \(hour) \(dayOfMonth) \(month) \(dayOfWeek)"
}

private func notExpressible(_ reason: String) -> HronError {
  .cron("not expressible as cron: \(reason)")
}

private func repeatsOnce(_ interval: Int, _ unit: String) throws(HronError) {
  if interval > 1 {
    throw notExpressible("multi-\(unit) repeats not supported")
  }
}

private func dayFields(_ expression: ScheduleExpression) throws(HronError) -> (String, String) {
  switch expression {
  case .intervalRepeat(_, _, _, _, let dayFilter):
    return ("*", dayFilter.map(filterField) ?? "*")
  case .dayRepeat(let interval, let days, _):
    try repeatsOnce(interval, "day")
    return ("*", filterField(days))
  case .weekRepeat(let interval, let days, _):
    try repeatsOnce(interval, "week")
    return ("*", weekdaysField(days))
  case .monthRepeat(let interval, let target, _):
    try repeatsOnce(interval, "month")
    switch target {
    case .days(let specs):
      return (listField(Array(Set(specs.flatMap(\.days))).sorted(), size: 31), "*")
    case .lastDay:
      return ("L", "*")
    case .lastWeekday:
      return ("LW", "*")
    case .nearestWeekday(_, .some):
      throw notExpressible("directional nearest weekday not supported")
    case .nearestWeekday(let day, nil):
      return ("\(day)W", "*")
    case .ordinalWeekday(let ordinal, let weekday):
      return ("*", ordinalField(ordinal, weekday))
    }
  case .yearRepeat(let interval, let target, _):
    try repeatsOnce(interval, "year")
    switch target {
    case .date(_, let day), .dayOfMonth(let day, _):
      return ("\(day)", "*")
    case .ordinalWeekday(let ordinal, let weekday, _):
      return ("*", ordinalField(ordinal, weekday))
    case .lastWeekday:
      return ("LW", "*")
    }
  case .singleDate(.iso, _):
    throw notExpressible("ISO dates do not repeat")
  case .singleDate(.named(_, let day), _):
    return ("\(day)", "*")
  }
}

private func monthField(_ schedule: Schedule) throws(HronError) -> String {
  let during = schedule.during
  if let month = ownMonth(schedule.expression) {
    guard during.isEmpty || during.contains(month) else {
      throw notExpressible("during excludes the schedule's month")
    }
    return "\(month.number)"
  }
  return during.isEmpty ? "*" : listField(Array(Set(during.map(\.number))).sorted(), size: 12)
}

private func ownMonth(_ expression: ScheduleExpression) -> MonthName? {
  switch expression {
  case .yearRepeat(_, let target, _):
    switch target {
    case .date(let month, _), .dayOfMonth(_, let month), .ordinalWeekday(_, _, let month),
      .lastWeekday(let month):
      month
    }
  case .singleDate(.named(let month, _), _):
    month
  default:
    nil
  }
}

private func timeFields(_ expression: ScheduleExpression) throws(HronError) -> (String, String) {
  let times = dailyMinutes(expression)
  let minutes = Array(Set(times.map { $0 % 60 })).sorted()
  let hours = Array(Set(times.map { $0 / 60 })).sorted()
  guard minutes.count * hours.count == times.count else {
    throw notExpressible("times are not every combination of their minutes and hours")
  }
  return (stepField(minutes, size: 60), stepField(hours, size: 24))
}

private func dailyMinutes(_ expression: ScheduleExpression) -> [Int] {
  let minutes: [Int] =
    switch expression {
    case .intervalRepeat(let interval, let unit, let from, let to, _):
      intervalSlots(interval: interval, unit: unit, from: from, to: to)
    case .dayRepeat(_, _, let times), .weekRepeat(_, _, let times), .monthRepeat(_, _, let times),
      .yearRepeat(_, _, let times), .singleDate(_, let times):
      times.map(\.minuteOfDay)
    }
  return Array(Set(minutes)).sorted()
}

private func filterField(_ filter: DayFilter) -> String {
  switch filter {
  case .every: "*"
  case .weekday: weekdaysField([.monday, .tuesday, .wednesday, .thursday, .friday])
  case .weekend: weekdaysField([.saturday, .sunday])
  case .days(let days): weekdaysField(days)
  }
}

private func weekdaysField(_ days: [Weekday]) -> String {
  listField(Array(Set(days.map(cronDay))).sorted(), size: 7)
}

private func ordinalField(_ ordinal: OrdinalPosition, _ weekday: Weekday) -> String {
  guard let index = cronOrdinals.firstIndex(of: ordinal) else { return "\(cronDay(weekday))L" }
  return "\(cronDay(weekday))#\(index + 1)"
}

private func cronDay(_ weekday: Weekday) -> Int {
  weekday.isoNumber % 7
}

private func stepField(_ values: [Int], size: Int) -> String {
  let first = values[0]
  let last = values[values.count - 1]
  let gap = values.count > 1 ? values[1] - first : nil
  let equalGaps = gap.map { gap in zip(values, values.dropFirst()).allSatisfy { $1 - $0 == gap } }
  switch gap {
  case _ where values.count == size: return "*"
  case nil: return "\(first)"
  case let gap? where equalGaps == true && first == 0 && last + gap == size: return "*/\(gap)"
  case 1? where equalGaps == true: return "\(first)-\(last)"
  case let gap? where equalGaps == true && values.count >= 3: return "\(first)-\(last)/\(gap)"
  default: return listField(values, size: size)
  }
}

private func listField(_ values: [Int], size: Int) -> String {
  guard values.count != size else { return "*" }
  return runs(values).map { $0 == $1 ? "\($0)" : "\($0)-\($1)" }.joined(separator: ",")
}

private func runs(_ sortedValues: [Int]) -> [(Int, Int)] {
  var runs: [(Int, Int)] = []
  for value in sortedValues {
    if let last = runs.last, last.1 + 1 == value {
      runs[runs.count - 1].1 = value
    } else {
      runs.append((value, value))
    }
  }
  return runs
}
