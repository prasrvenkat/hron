package io.hron.lexer;

import io.hron.Span;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;

public record Token(
    TokenKind kind,
    Span span,
    Weekday dayNameVal,
    MonthName monthNameVal,
    OrdinalPosition ordinalVal,
    IntervalUnit unitVal,
    int numberVal,
    int timeHour,
    int timeMinute,
    String isoDateVal,
    String timezoneVal) {
  public static Token keyword(TokenKind kind, Span span) {
    return new Token(kind, span, null, null, null, null, 0, 0, 0, null, null);
  }

  public static Token dayName(Weekday day, Span span) {
    return new Token(TokenKind.DAY_NAME, span, day, null, null, null, 0, 0, 0, null, null);
  }

  public static Token monthName(MonthName month, Span span) {
    return new Token(TokenKind.MONTH_NAME, span, null, month, null, null, 0, 0, 0, null, null);
  }

  public static Token ordinal(OrdinalPosition ord, Span span) {
    return new Token(TokenKind.ORDINAL, span, null, null, ord, null, 0, 0, 0, null, null);
  }

  public static Token intervalUnit(IntervalUnit unit, Span span) {
    return new Token(TokenKind.INTERVAL_UNIT, span, null, null, null, unit, 0, 0, 0, null, null);
  }

  public static Token number(int value, Span span) {
    return new Token(TokenKind.NUMBER, span, null, null, null, null, value, 0, 0, null, null);
  }

  public static Token ordinalNumber(int value, Span span) {
    return new Token(
        TokenKind.ORDINAL_NUMBER, span, null, null, null, null, value, 0, 0, null, null);
  }

  public static Token time(int hour, int minute, Span span) {
    return new Token(TokenKind.TIME, span, null, null, null, null, 0, hour, minute, null, null);
  }

  public static Token isoDate(String date, Span span) {
    return new Token(TokenKind.ISO_DATE, span, null, null, null, null, 0, 0, 0, date, null);
  }

  public static Token comma(Span span) {
    return new Token(TokenKind.COMMA, span, null, null, null, null, 0, 0, 0, null, null);
  }

  public static Token timezone(String tz, Span span) {
    return new Token(TokenKind.TIMEZONE, span, null, null, null, null, 0, 0, 0, null, tz);
  }
}
