package io.hron.lexer;

import io.hron.Span;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;

/**
 * Represents a lexed token.
 *
 * @param kind the type of token
 * @param span the location in the input
 * @param dayNameVal the weekday value (for DAY_NAME tokens)
 * @param monthNameVal the month value (for MONTH_NAME tokens)
 * @param ordinalVal the ordinal value (for ORDINAL tokens)
 * @param unitVal the interval unit value (for INTERVAL_UNIT tokens)
 * @param numberVal the number value (for NUMBER and ORDINAL_NUMBER tokens)
 * @param timeHour the hour (for TIME tokens)
 * @param timeMinute the minute (for TIME tokens)
 * @param isoDateVal the ISO date string (for ISO_DATE tokens)
 * @param timezoneVal the timezone string (for TIMEZONE tokens)
 */
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
  /** Creates a simple keyword token. */
  public static Token keyword(TokenKind kind, Span span) {
    return new Token(kind, span, null, null, null, null, 0, 0, 0, null, null);
  }

  /** Creates a day name token. */
  public static Token dayName(Weekday day, Span span) {
    return new Token(TokenKind.DAY_NAME, span, day, null, null, null, 0, 0, 0, null, null);
  }

  /** Creates a month name token. */
  public static Token monthName(MonthName month, Span span) {
    return new Token(TokenKind.MONTH_NAME, span, null, month, null, null, 0, 0, 0, null, null);
  }

  /** Creates an ordinal token. */
  public static Token ordinal(OrdinalPosition ord, Span span) {
    return new Token(TokenKind.ORDINAL, span, null, null, ord, null, 0, 0, 0, null, null);
  }

  /** Creates an interval unit token. */
  public static Token intervalUnit(IntervalUnit unit, Span span) {
    return new Token(TokenKind.INTERVAL_UNIT, span, null, null, null, unit, 0, 0, 0, null, null);
  }

  /** Creates a number token. */
  public static Token number(int value, Span span) {
    return new Token(TokenKind.NUMBER, span, null, null, null, null, value, 0, 0, null, null);
  }

  /** Creates an ordinal number token (e.g., "1st", "15th"). */
  public static Token ordinalNumber(int value, Span span) {
    return new Token(
        TokenKind.ORDINAL_NUMBER, span, null, null, null, null, value, 0, 0, null, null);
  }

  /** Creates a time token. */
  public static Token time(int hour, int minute, Span span) {
    return new Token(TokenKind.TIME, span, null, null, null, null, 0, hour, minute, null, null);
  }

  /** Creates an ISO date token. */
  public static Token isoDate(String date, Span span) {
    return new Token(TokenKind.ISO_DATE, span, null, null, null, null, 0, 0, 0, date, null);
  }

  /** Creates a comma token. */
  public static Token comma(Span span) {
    return new Token(TokenKind.COMMA, span, null, null, null, null, 0, 0, 0, null, null);
  }

  /** Creates a timezone token. */
  public static Token timezone(String tz, Span span) {
    return new Token(TokenKind.TIMEZONE, span, null, null, null, null, 0, 0, 0, null, tz);
  }
}
