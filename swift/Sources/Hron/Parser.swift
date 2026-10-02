/// The `{what}` of each `expected {what}, got ...` error, one per phrase in the position table
/// of spec/README.md, "Parse errors".
private enum Expected {
  static let everyOrOn = "'every' or 'on'"
  static let repeater =
    "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number"
  static let unit = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')"
  static let at = "'at'"
  static let time = "a time (HH:MM)"
  static let from = "'from'"
  static let to = "'to'"
  static let dayTarget = "'day', 'weekday', 'weekend' or a day name"
  static let on = "'on'"
  static let dayName = "a day name"
  static let the = "'the'"
  static let monthTarget =
    "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'"
  static let monthLast = "'day', 'weekday' or a day name"
  static let nearest = "'nearest'"
  static let weekday = "'weekday'"
  static let dayOfMonth = "a day such as 15th"
  static let yearTarget = "a month name or 'the'"
  static let yearThe = "a day such as 15th, 'last' or an ordinal such as 'first'"
  static let yearLast = "'weekday' or a day name"
  static let of = "'of'"
  static let monthName = "a month name"
  static let dayNumber = "a day number"
  static let date = "a date (YYYY-MM-DD, or a month and day)"
  static let isoDate = "a date (YYYY-MM-DD)"
  static let timezone = "a timezone"
}

private let clauseOrder: [(kind: TokenKind, keyword: String)] = [
  (.except, "except"), (.until, "until"), (.starting, "starting"), (.during, "during"),
  (.in, "in"),
]

struct Parser {
  private let lexer: Lexer
  private let tokens: [Token]
  private var position = 0

  private var except: [Exception] = []
  private var until: UntilSpec?
  private var untilTokens: (start: Int, end: Int)?
  private var starting: CivilDate?
  private var during: [MonthName] = []
  private var zone: IANATimeZone?

  static func parse(_ input: String) throws(HronError) -> Schedule {
    var lexer = Lexer(input)
    let tokens = try lexer.tokenize()
    guard !tokens.isEmpty else {
      throw .parse("empty expression", span: HronError.Span(start: 0, end: 0), input: input)
    }
    var parser = Parser(lexer: lexer, tokens: tokens)
    let expression = try parser.parseExpression()
    try parser.parseClauses()
    if parser.position < tokens.count {
      throw parser.leftover()
    }
    // spec/README.md, "Parse errors": every other error wins over a named until without
    // starting.
    try parser.checkNamedUntil()
    return Schedule(
      expression: expression, zone: parser.zone, except: parser.except, until: parser.until,
      starting: parser.starting, during: parser.during)
  }

  private init(lexer: Lexer, tokens: [Token]) {
    self.lexer = lexer
    self.tokens = tokens
  }

  private var peek: TokenKind? {
    position < tokens.count ? tokens[position].kind : nil
  }

  private var previous: Token { tokens[position - 1] }

  @discardableResult
  private mutating func advance() -> Token {
    position += 1
    return tokens[position - 1]
  }

  private mutating func eat(_ kind: TokenKind) -> Bool {
    guard peek == kind else { return false }
    position += 1
    return true
  }

  private mutating func expect(_ kind: TokenKind, _ what: String) throws(HronError) {
    guard eat(kind) else { throw expected(what) }
  }

  private func text(_ token: Token) -> String {
    lexer.text(token.start, token.end)
  }

  private func error(_ message: String, from start: Int, to end: Int) -> HronError {
    .parse(message, span: HronError.Span(start: start, end: end), input: lexer.input)
  }

  private func expected(_ what: String) -> HronError {
    guard position < tokens.count else {
      let end = tokens.last?.end ?? 0
      return error("expected \(what), got end of input", from: end, to: end)
    }
    let token = tokens[position]
    return error("expected \(what), got '\(text(token))'", from: token.start, to: token.end)
  }

  private mutating func parseExpression() throws(HronError) -> ScheduleExpression {
    switch peek {
    case .every:
      advance()
      return try parseEvery()
    case .on:
      advance()
      let date = try parseDate()
      return .singleDate(date: date, times: try parseAtTimes())
    default:
      throw expected(Expected.everyOrOn)
    }
  }

  private mutating func parseClauses() throws(HronError) {
    if eat(.except) {
      except = try parseList { (parser) throws(HronError) in
        switch try parser.parseDate() {
        case .iso(let date): .iso(date)
        case .named(let month, let day): .named(month: month, day: day)
        }
      }
    }
    if peek == .until {
      let start = advance().start
      until =
        switch try parseDate() {
        case .iso(let date): .iso(date)
        case .named(let month, let day): .named(month: month, day: day)
        }
      untilTokens = (start, previous.end)
    }
    if eat(.starting) {
      guard peek == .isoDate else { throw expected(Expected.isoDate) }
      starting = try isoDate(advance())
    }
    if eat(.during) {
      during = try parseList { (parser) throws(HronError) in try parser.parseMonthName() }
    }
    if eat(.in) {
      guard peek == .timezone else { throw expected(Expected.timezone) }
      zone = try timezone(advance())
    }
  }

  private func leftover() -> HronError {
    let token = tokens[position]
    // Every clause holds at least one item, so a clause was read exactly when its field is set.
    let read = [!except.isEmpty, until != nil, starting != nil, !during.isEmpty, zone != nil]
    let clause = clauseOrder.firstIndex { $0.kind == token.kind }
    let message =
      switch (clause, read.lastIndex(of: true)) {
      case (let clause?, _) where read[clause]:
        "duplicate '\(clauseOrder[clause].keyword)' clause"
      case (let clause?, let last?):
        "'\(clauseOrder[clause].keyword)' must come before '\(clauseOrder[last].keyword)'"
      default:
        "unexpected '\(text(token))' after the schedule"
      }
    return error(message, from: token.start, to: token.end)
  }

  private func checkNamedUntil() throws(HronError) {
    guard case .named(let month, let day) = until, starting == nil, let untilTokens else {
      return
    }
    let named = "until \(month.shortName) \(day)"
    throw .parse(
      "\(named) has no year: add a starting date, or use an ISO date",
      span: HronError.Span(start: untilTokens.start, end: untilTokens.end), input: lexer.input,
      suggestion: "\(named) starting YYYY-MM-DD")
  }

  private mutating func parseList<Item>(
    _ parseItem: (inout Parser) throws(HronError) -> Item
  ) throws(HronError) -> [Item] {
    var items = [try parseItem(&self)]
    while eat(.comma) {
      items.append(try parseItem(&self))
    }
    return items
  }

  private mutating func parseDate() throws(HronError) -> DateSpec {
    switch peek {
    case .isoDate:
      let token = advance()
      _ = try isoDate(token)
      return .iso(text(token))
    case .monthName(let month):
      advance()
      return .named(month: month, day: try parseDay(of: month))
    default:
      throw expected(Expected.date)
    }
  }

  private func isoDate(_ token: Token) throws(HronError) -> CivilDate {
    guard let date = CivilDate(iso: text(token)) else {
      throw error(
        "date must be a calendar date from 0001-01-01 to 9999-12-31, got \(text(token))",
        from: token.start, to: token.end)
    }
    return date
  }

  private func timezone(_ token: Token) throws(HronError) -> IANATimeZone {
    let name = text(token)
    guard let zone = IANATimeZone(name) else {
      throw error(
        "timezone must be UTC or an Area/Location name such as America/New_York, got \(name)",
        from: token.start, to: token.end)
    }
    return zone
  }

  private mutating func parseEvery() throws(HronError) -> ScheduleExpression {
    switch peek {
    case .day:
      advance()
      return .dayRepeat(interval: 1, days: .every, times: try parseAtTimes())
    case .weekday:
      advance()
      return .dayRepeat(interval: 1, days: .weekday, times: try parseAtTimes())
    case .weekend:
      advance()
      return .dayRepeat(interval: 1, days: .weekend, times: try parseAtTimes())
    case .dayName:
      let days = try parseDayList()
      return .dayRepeat(interval: 1, days: .days(days), times: try parseAtTimes())
    case .week:
      advance()
      return try parseWeekRepeat(interval: 1)
    case .month:
      advance()
      return try parseMonthRepeat(interval: 1)
    case .year:
      advance()
      return try parseYearRepeat(interval: 1)
    case .number(let interval):
      return try parseNumberRepeat(interval)
    default:
      throw expected(Expected.repeater)
    }
  }

  private mutating func parseNumberRepeat(_ interval: Int) throws(HronError) -> ScheduleExpression {
    let number = advance()
    guard interval > 0 else {
      throw error(
        "interval must be 1-2147483647, got \(text(number))", from: number.start, to: number.end)
    }
    switch peek {
    case .week:
      advance()
      return try parseWeekRepeat(interval: interval)
    case .intervalUnit(let unit):
      advance()
      return try parseIntervalRepeat(interval: interval, unit: unit)
    case .day:
      advance()
      return .dayRepeat(interval: interval, days: .every, times: try parseAtTimes())
    case .month:
      advance()
      return try parseMonthRepeat(interval: interval)
    case .year:
      advance()
      return try parseYearRepeat(interval: interval)
    default:
      throw expected(Expected.unit)
    }
  }

  private mutating func parseIntervalRepeat(interval: Int, unit: IntervalUnit) throws(HronError)
    -> ScheduleExpression
  {
    try expect(.from, Expected.from)
    let from = try parseTime()
    let fromToken = previous
    try expect(.to, Expected.to)
    let to = try parseTime()
    let toToken = previous
    guard from.minuteOfDay <= to.minuteOfDay else {
      throw error(
        "time window must not run backwards: \(text(fromToken)) to \(text(toToken))"
          + " (a window cannot cross midnight)",
        from: fromToken.start, to: toToken.end)
    }
    let dayFilter = eat(.on) ? try parseDayTarget() : nil
    return .intervalRepeat(
      interval: interval, unit: unit, from: from, to: to, dayFilter: dayFilter)
  }

  private mutating func parseWeekRepeat(interval: Int) throws(HronError) -> ScheduleExpression {
    try expect(.on, Expected.on)
    let days = try parseDayList()
    return .weekRepeat(interval: interval, days: days, times: try parseAtTimes())
  }

  private mutating func parseMonthRepeat(interval: Int) throws(HronError) -> ScheduleExpression {
    try expect(.on, Expected.on)
    try expect(.the, Expected.the)
    let target: MonthTarget
    switch peek {
    case .last:
      advance()
      switch peek {
      case .day: target = .lastDay
      case .weekday: target = .lastWeekday
      case .dayName(let weekday): target = .ordinalWeekday(ordinal: .last, weekday: weekday)
      default: throw expected(Expected.monthLast)
      }
      advance()
    case .ordinal(let ordinal):
      advance()
      target = .ordinalWeekday(ordinal: ordinal, weekday: try parseDayName())
    case .ordinalNumber:
      target = .days(try parseList { (parser) throws(HronError) in try parser.parseDaySpec() })
    case .next, .previous, .nearest:
      target = try parseNearestWeekday()
    default:
      throw expected(Expected.monthTarget)
    }
    return .monthRepeat(interval: interval, target: target, times: try parseAtTimes())
  }

  private mutating func parseNearestWeekday() throws(HronError) -> MonthTarget {
    let direction: NearestDirection? =
      if eat(.next) { .next } else if eat(.previous) { .previous } else { nil }
    try expect(.nearest, Expected.nearest)
    try expect(.weekday, Expected.weekday)
    try expect(.to, Expected.to)
    return .nearestWeekday(day: try parseOrdinalDay().day, direction: direction)
  }

  private mutating func parseDaySpec() throws(HronError) -> DayOfMonthSpec {
    let start = try parseOrdinalDay()
    guard eat(.to) else { return .single(start.day) }
    let end = try parseOrdinalDay()
    guard start.day <= end.day else {
      throw error(
        "day range must not run backwards: \(text(start.token)) to \(text(end.token))",
        from: start.token.start, to: end.token.end)
    }
    return .range(start: start.day, end: end.day)
  }

  private mutating func parseOrdinalDay() throws(HronError) -> (day: Int, token: Token) {
    guard case .ordinalNumber(let n) = peek else { throw expected(Expected.dayOfMonth) }
    let token = advance()
    return (try dayOfMonth(n, token), token)
  }

  private mutating func parseDay(of month: MonthName) throws(HronError) -> Int {
    let n: Int
    switch peek {
    case .number(let value), .ordinalNumber(let value): n = value
    default: throw expected(Expected.dayNumber)
    }
    let token = advance()
    let day = try dayOfMonth(n, token)
    try checkDay(day, token, in: month)
    return day
  }

  private func dayOfMonth(_ n: Int, _ token: Token) throws(HronError) -> Int {
    guard (1...31).contains(n) else {
      throw error("day must be 1-31, got \(text(token))", from: token.start, to: token.end)
    }
    return n
  }

  private func checkDay(_ day: Int, _ token: Token, in month: MonthName) throws(HronError) {
    guard day <= month.maxDay else {
      throw error(
        "day must be 1-\(month.maxDay) for \(month.shortName), got \(text(token))",
        from: token.start, to: token.end)
    }
  }

  private mutating func parseYearRepeat(interval: Int) throws(HronError) -> ScheduleExpression {
    try expect(.on, Expected.on)
    let target: YearTarget
    switch peek {
    case .the:
      advance()
      target = try parseYearTargetAfterThe()
    case .monthName(let month):
      advance()
      target = .date(month: month, day: try parseDay(of: month))
    default:
      throw expected(Expected.yearTarget)
    }
    return .yearRepeat(interval: interval, target: target, times: try parseAtTimes())
  }

  private mutating func parseYearTargetAfterThe() throws(HronError) -> YearTarget {
    switch peek {
    case .last:
      advance()
      switch peek {
      case .weekday:
        advance()
        return .lastWeekday(month: try parseOfMonth())
      case .dayName(let weekday):
        advance()
        return .ordinalWeekday(ordinal: .last, weekday: weekday, month: try parseOfMonth())
      default:
        throw expected(Expected.yearLast)
      }
    case .ordinal(let ordinal):
      advance()
      let weekday = try parseDayName()
      return .ordinalWeekday(ordinal: ordinal, weekday: weekday, month: try parseOfMonth())
    case .ordinalNumber:
      let (day, token) = try parseOrdinalDay()
      let month = try parseOfMonth()
      try checkDay(day, token, in: month)
      return .dayOfMonth(day: day, month: month)
    default:
      throw expected(Expected.yearThe)
    }
  }

  private mutating func parseOfMonth() throws(HronError) -> MonthName {
    try expect(.of, Expected.of)
    return try parseMonthName()
  }

  private mutating func parseMonthName() throws(HronError) -> MonthName {
    guard case .monthName(let month) = peek else { throw expected(Expected.monthName) }
    advance()
    return month
  }

  private mutating func parseDayTarget() throws(HronError) -> DayFilter {
    switch peek {
    case .day:
      advance()
      return .every
    case .weekday:
      advance()
      return .weekday
    case .weekend:
      advance()
      return .weekend
    case .dayName:
      return .days(try parseDayList())
    default:
      throw expected(Expected.dayTarget)
    }
  }

  private mutating func parseDayName() throws(HronError) -> Weekday {
    guard case .dayName(let weekday) = peek else { throw expected(Expected.dayName) }
    advance()
    return weekday
  }

  private mutating func parseDayList() throws(HronError) -> [Weekday] {
    try parseList { (parser) throws(HronError) in try parser.parseDayName() }
  }

  private mutating func parseAtTimes() throws(HronError) -> [TimeOfDay] {
    try expect(.at, Expected.at)
    return try parseList { (parser) throws(HronError) in try parser.parseTime() }
  }

  private mutating func parseTime() throws(HronError) -> TimeOfDay {
    guard case .time(let time) = peek else { throw expected(Expected.time) }
    advance()
    return time
  }
}
