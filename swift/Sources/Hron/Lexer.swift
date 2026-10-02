/// Offsets count Unicode scalars, the code points error spans are given in.
struct Token {
  let kind: TokenKind
  let start: Int
  let end: Int
}

enum TokenKind: Equatable {
  case every, on, at, from, to, `in`, of, the, last, except, until, starting, during
  case nearest, next, previous
  case day, weekday, weekend, week, month, year
  case dayName(Weekday)
  case monthName(MonthName)
  case ordinal(OrdinalPosition)
  case intervalUnit(IntervalUnit)
  case number(Int)
  case ordinalNumber(Int)
  case time(TimeOfDay)
  case isoDate
  case comma
  case timezone
}

struct Lexer {
  private static let maxNumber: Int64 = 2_147_483_647

  let input: String
  let scalars: [Unicode.Scalar]
  private var position = 0

  init(_ input: String) {
    self.input = input
    scalars = Array(input.unicodeScalars)
  }

  func text(_ start: Int, _ end: Int) -> String {
    String(String.UnicodeScalarView(scalars[start..<end]))
  }

  mutating func tokenize() throws(HronError) -> [Token] {
    var tokens: [Token] = []
    while true {
      advance(while: isSeparator)
      guard position < scalars.count else { return tokens }
      let start = position
      let scalar = scalars[position]
      let kind: TokenKind
      if tokens.last?.kind == .in {
        advance { !isSeparator($0) }
        kind = .timezone
      } else if scalar == "," {
        position += 1
        kind = .comma
      } else if isLetter(scalar) {
        kind = try word(from: start)
      } else if isDigit(scalar) {
        kind = try digits(from: start)
      } else {
        throw unexpectedCharacter(scalar, at: start)
      }
      tokens.append(Token(kind: kind, start: start, end: position))
    }
  }

  private mutating func advance(while matches: (Unicode.Scalar) -> Bool) {
    while position < scalars.count, matches(scalars[position]) {
      position += 1
    }
  }

  private func error(_ message: String, from start: Int) -> HronError {
    .lex(message, span: HronError.Span(start: start, end: position), input: input)
  }

  private mutating func word(from start: Int) throws(HronError) -> TokenKind {
    advance { isLetter($0) || isDigit($0) || $0 == "_" }
    let word = text(start, position)
    guard let kind = keyword(word.lowercased()) else {
      throw error("unknown keyword '\(word)'", from: start)
    }
    return kind
  }

  private mutating func digits(from start: Int) throws(HronError) -> TokenKind {
    advance(while: isDigit)
    if position - start == 4, isISODateTail(scalars[position...]) {
      position += "-MM-DD".count
      return .isoDate
    }
    if position < scalars.count, scalars[position] == ":" {
      return try time(from: start)
    }
    guard let value = numberValue(scalars[start..<position]) else {
      throw error("number must be at most 2147483647", from: start)
    }
    let suffix = scalars[position..<min(position + 2, scalars.count)].map(asciiLowercased)
    if [["s", "t"], ["n", "d"], ["r", "d"], ["t", "h"]].contains(suffix) {
      position += 2
      return .ordinalNumber(value)
    }
    return .number(value)
  }

  private mutating func time(from start: Int) throws(HronError) -> TokenKind {
    let colon = position
    position += 1
    advance(while: isDigit)
    let hourDigits = scalars[start..<colon]
    let minuteDigits = scalars[(colon + 1)..<position]
    let written = text(start, position)
    guard (1...2).contains(hourDigits.count), minuteDigits.count == 2,
      let hour = numberValue(hourDigits), let minute = numberValue(minuteDigits)
    else {
      throw error("time must be H:MM or HH:MM, got \(written)", from: start)
    }
    guard hour <= 23, minute <= 59 else {
      throw error("time must be 00:00-23:59, got \(written)", from: start)
    }
    return .time(TimeOfDay(hour: hour, minute: minute))
  }

  private func unexpectedCharacter(_ scalar: Unicode.Scalar, at start: Int) -> HronError {
    let hex = String(scalar.value, radix: 16, uppercase: true)
    // `'` is excluded because `'''` would not read as a quoted character.
    let shown =
      ("!"..."~").contains(scalar) && scalar != "'"
      ? "'\(scalar)'"
      : "U+" + String(repeating: "0", count: max(4 - hex.count, 0)) + hex
    return .lex(
      "unexpected character \(shown)", span: HronError.Span(start: start, end: start + 1),
      input: input)
  }

  /// Checked at every digit, so a run of any length cannot overflow.
  private func numberValue(_ digits: ArraySlice<Unicode.Scalar>) -> Int? {
    var value: Int64 = 0
    for digit in digits {
      value = value * 10 + Int64(digit.value - 48)
      if value > Self.maxNumber {
        return nil
      }
    }
    return Int(value)
  }
}

/// Only these four separate tokens; any other whitespace is an unexpected character.
private func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
  scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
}

private func isLetter(_ scalar: Unicode.Scalar) -> Bool {
  ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
}

private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
  ("0"..."9").contains(scalar)
}

private func asciiLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
  ("A"..."Z").contains(scalar) ? Unicode.Scalar(UInt8(scalar.value + 32)) : scalar
}

private func isISODateTail(_ rest: ArraySlice<Unicode.Scalar>) -> Bool {
  let tail = Array(rest.prefix(6))
  return tail.count == 6 && tail[0] == "-" && tail[3] == "-"
    && [tail[1], tail[2], tail[4], tail[5]].allSatisfy(isDigit)
}

private func keyword(_ word: String) -> TokenKind? {
  switch word {
  case "every": .every
  case "on": .on
  case "at": .at
  case "from": .from
  case "to": .to
  case "in": .in
  case "of": .of
  case "the": .the
  case "last": .last
  case "except": .except
  case "until": .until
  case "starting": .starting
  case "during": .during
  case "nearest": .nearest
  case "next": .next
  case "previous": .previous
  case "day", "days": .day
  case "weekday", "weekdays": .weekday
  case "weekend", "weekends": .weekend
  case "week", "weeks": .week
  case "month", "months": .month
  case "year", "years": .year
  case "first": .ordinal(.first)
  case "second": .ordinal(.second)
  case "third": .ordinal(.third)
  case "fourth": .ordinal(.fourth)
  case "fifth": .ordinal(.fifth)
  case "min", "mins", "minute", "minutes": .intervalUnit(.minutes)
  case "hour", "hours", "hr", "hrs": .intervalUnit(.hours)
  default:
    Weekday(word: word).map(TokenKind.dayName) ?? MonthName(word: word).map(TokenKind.monthName)
  }
}
