package io.hron.internal.lexer;

import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;

/**
 * {@code start} and {@code end} are UTF-16 offsets into the input; {@link Lexer#span} converts them
 * to the code points an error reports.
 */
public record Token(
    TokenKind kind,
    int start,
    int end,
    Weekday dayNameVal,
    MonthName monthNameVal,
    OrdinalPosition ordinalVal,
    IntervalUnit unitVal,
    int numberVal,
    int timeHour,
    int timeMinute) {
  static Token keyword(TokenKind kind) {
    return new Token(kind, 0, 0, null, null, null, null, 0, 0, 0);
  }

  static Token dayName(Weekday day) {
    return new Token(TokenKind.DAY_NAME, 0, 0, day, null, null, null, 0, 0, 0);
  }

  static Token monthName(MonthName month) {
    return new Token(TokenKind.MONTH_NAME, 0, 0, null, month, null, null, 0, 0, 0);
  }

  static Token ordinal(OrdinalPosition ord) {
    return new Token(TokenKind.ORDINAL, 0, 0, null, null, ord, null, 0, 0, 0);
  }

  static Token intervalUnit(IntervalUnit unit) {
    return new Token(TokenKind.INTERVAL_UNIT, 0, 0, null, null, null, unit, 0, 0, 0);
  }

  static Token number(TokenKind kind, int value) {
    return new Token(kind, 0, 0, null, null, null, null, value, 0, 0);
  }

  static Token time(int hour, int minute) {
    return new Token(TokenKind.TIME, 0, 0, null, null, null, null, 0, hour, minute);
  }

  Token at(int start, int end) {
    return new Token(
        kind,
        start,
        end,
        dayNameVal,
        monthNameVal,
        ordinalVal,
        unitVal,
        numberVal,
        timeHour,
        timeMinute);
  }
}
