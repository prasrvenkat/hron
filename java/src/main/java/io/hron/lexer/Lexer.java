package io.hron.lexer;

import io.hron.HronException;
import io.hron.Span;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/** Tokenizes input strings into a list of tokens. */
public final class Lexer {
  private final String input;
  private int pos;
  private boolean afterIn;

  private Lexer(String input) {
    this.input = input;
    this.pos = 0;
    this.afterIn = false;
  }

  /**
   * Tokenizes the input string into a list of tokens.
   *
   * @param input the input string to tokenize
   * @return a list of tokens
   * @throws HronException if the input contains invalid tokens
   */
  public static List<Token> tokenize(String input) throws HronException {
    return new Lexer(input).doTokenize();
  }

  private List<Token> doTokenize() throws HronException {
    List<Token> tokens = new ArrayList<>();
    while (true) {
      skipWhitespace();
      if (pos >= input.length()) {
        break;
      }

      if (afterIn) {
        afterIn = false;
        tokens.add(lexTimezone());
        continue;
      }

      int start = pos;
      char ch = input.charAt(pos);

      if (ch == ',') {
        pos++;
        tokens.add(Token.comma(new Span(start, pos)));
        continue;
      }

      if (isDigit(ch)) {
        tokens.add(lexNumberOrTimeOrDate());
        continue;
      }

      if (isAlpha(ch)) {
        tokens.add(lexWord());
        continue;
      }

      throw HronException.lex(
          "unexpected character '" + ch + "'", new Span(start, start + 1), input);
    }

    return tokens;
  }

  private void skipWhitespace() {
    while (pos < input.length() && isWhitespace(input.charAt(pos))) {
      pos++;
    }
  }

  private Token lexTimezone() throws HronException {
    skipWhitespace();
    int start = pos;
    while (pos < input.length() && !isWhitespace(input.charAt(pos))) {
      pos++;
    }
    String tz = input.substring(start, pos);
    if (tz.isEmpty()) {
      throw HronException.lex("expected timezone after 'in'", new Span(start, start + 1), input);
    }
    return Token.timezone(tz, new Span(start, pos));
  }

  private Token lexNumberOrTimeOrDate() throws HronException {
    int start = pos;

    // Read digits
    int numStart = pos;
    while (pos < input.length() && isDigit(input.charAt(pos))) {
      pos++;
    }
    String digits = input.substring(numStart, pos);

    // Check for ISO date: YYYY-MM-DD
    if (digits.length() == 4 && pos < input.length() && input.charAt(pos) == '-') {
      String remaining = input.substring(start);
      if (remaining.length() >= 10
          && remaining.charAt(4) == '-'
          && isDigit(remaining.charAt(5))
          && isDigit(remaining.charAt(6))
          && remaining.charAt(7) == '-'
          && isDigit(remaining.charAt(8))
          && isDigit(remaining.charAt(9))) {
        pos = start + 10;
        return Token.isoDate(input.substring(start, pos), new Span(start, pos));
      }
    }

    // Check for time: HH:MM or H:MM
    if ((digits.length() == 1 || digits.length() == 2)
        && pos < input.length()
        && input.charAt(pos) == ':') {
      pos++; // skip ':'
      int minStart = pos;
      while (pos < input.length() && isDigit(input.charAt(pos))) {
        pos++;
      }
      String minDigits = input.substring(minStart, pos);
      if (minDigits.length() == 2) {
        int hour = Integer.parseInt(digits);
        int minute = Integer.parseInt(minDigits);
        if (hour > 23 || minute > 59) {
          throw HronException.lex("invalid time", new Span(start, pos), input);
        }
        return Token.time(hour, minute, new Span(start, pos));
      }
    }

    int num = Integer.parseInt(digits);

    // Check for ordinal suffix: st, nd, rd, th
    if (pos + 1 < input.length()) {
      String suffix = input.substring(pos, pos + 2).toLowerCase();
      if (suffix.equals("st")
          || suffix.equals("nd")
          || suffix.equals("rd")
          || suffix.equals("th")) {
        pos += 2;
        return Token.ordinalNumber(num, new Span(start, pos));
      }
    }

    return Token.number(num, new Span(start, pos));
  }

  private Token lexWord() throws HronException {
    int start = pos;
    while (pos < input.length()
        && (isAlphanumeric(input.charAt(pos)) || input.charAt(pos) == '_')) {
      pos++;
    }
    String word = input.substring(start, pos).toLowerCase();
    Span span = new Span(start, pos);

    Token tok = KEYWORD_MAP.get(word);
    if (tok == null) {
      throw HronException.lex("unknown keyword '" + word + "'", span, input);
    }

    // Create a new token with the actual span
    Token result =
        switch (tok.kind()) {
          case DAY_NAME -> Token.dayName(tok.dayNameVal(), span);
          case MONTH_NAME -> Token.monthName(tok.monthNameVal(), span);
          case ORDINAL -> Token.ordinal(tok.ordinalVal(), span);
          case INTERVAL_UNIT -> Token.intervalUnit(tok.unitVal(), span);
          default -> Token.keyword(tok.kind(), span);
        };

    if (tok.kind() == TokenKind.IN) {
      afterIn = true;
    }

    return result;
  }

  private static boolean isDigit(char c) {
    return c >= '0' && c <= '9';
  }

  private static boolean isAlpha(char c) {
    return Character.isLetter(c);
  }

  private static boolean isAlphanumeric(char c) {
    return isAlpha(c) || isDigit(c);
  }

  private static boolean isWhitespace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
  }

  // Keyword map - values have dummy spans, actual spans are set when returning
  private static final Map<String, Token> KEYWORD_MAP;
  private static final Span DUMMY_SPAN = new Span(0, 0);

  static {
    KEYWORD_MAP =
        Map.ofEntries(
            // Keywords
            Map.entry("every", Token.keyword(TokenKind.EVERY, DUMMY_SPAN)),
            Map.entry("on", Token.keyword(TokenKind.ON, DUMMY_SPAN)),
            Map.entry("at", Token.keyword(TokenKind.AT, DUMMY_SPAN)),
            Map.entry("from", Token.keyword(TokenKind.FROM, DUMMY_SPAN)),
            Map.entry("to", Token.keyword(TokenKind.TO, DUMMY_SPAN)),
            Map.entry("in", Token.keyword(TokenKind.IN, DUMMY_SPAN)),
            Map.entry("of", Token.keyword(TokenKind.OF, DUMMY_SPAN)),
            Map.entry("the", Token.keyword(TokenKind.THE, DUMMY_SPAN)),
            Map.entry("last", Token.keyword(TokenKind.LAST, DUMMY_SPAN)),
            Map.entry("except", Token.keyword(TokenKind.EXCEPT, DUMMY_SPAN)),
            Map.entry("until", Token.keyword(TokenKind.UNTIL, DUMMY_SPAN)),
            Map.entry("starting", Token.keyword(TokenKind.STARTING, DUMMY_SPAN)),
            Map.entry("during", Token.keyword(TokenKind.DURING, DUMMY_SPAN)),
            Map.entry("year", Token.keyword(TokenKind.YEAR, DUMMY_SPAN)),
            Map.entry("years", Token.keyword(TokenKind.YEAR, DUMMY_SPAN)),
            Map.entry("day", Token.keyword(TokenKind.DAY, DUMMY_SPAN)),
            Map.entry("days", Token.keyword(TokenKind.DAY, DUMMY_SPAN)),
            Map.entry("weekday", Token.keyword(TokenKind.WEEKDAY, DUMMY_SPAN)),
            Map.entry("weekdays", Token.keyword(TokenKind.WEEKDAY, DUMMY_SPAN)),
            Map.entry("weekend", Token.keyword(TokenKind.WEEKEND, DUMMY_SPAN)),
            Map.entry("weekends", Token.keyword(TokenKind.WEEKEND, DUMMY_SPAN)),
            Map.entry("weeks", Token.keyword(TokenKind.WEEKS, DUMMY_SPAN)),
            Map.entry("week", Token.keyword(TokenKind.WEEKS, DUMMY_SPAN)),
            Map.entry("month", Token.keyword(TokenKind.MONTH, DUMMY_SPAN)),
            Map.entry("months", Token.keyword(TokenKind.MONTH, DUMMY_SPAN)),

            // Day names
            Map.entry("monday", Token.dayName(Weekday.MONDAY, DUMMY_SPAN)),
            Map.entry("mon", Token.dayName(Weekday.MONDAY, DUMMY_SPAN)),
            Map.entry("tuesday", Token.dayName(Weekday.TUESDAY, DUMMY_SPAN)),
            Map.entry("tue", Token.dayName(Weekday.TUESDAY, DUMMY_SPAN)),
            Map.entry("wednesday", Token.dayName(Weekday.WEDNESDAY, DUMMY_SPAN)),
            Map.entry("wed", Token.dayName(Weekday.WEDNESDAY, DUMMY_SPAN)),
            Map.entry("thursday", Token.dayName(Weekday.THURSDAY, DUMMY_SPAN)),
            Map.entry("thu", Token.dayName(Weekday.THURSDAY, DUMMY_SPAN)),
            Map.entry("friday", Token.dayName(Weekday.FRIDAY, DUMMY_SPAN)),
            Map.entry("fri", Token.dayName(Weekday.FRIDAY, DUMMY_SPAN)),
            Map.entry("saturday", Token.dayName(Weekday.SATURDAY, DUMMY_SPAN)),
            Map.entry("sat", Token.dayName(Weekday.SATURDAY, DUMMY_SPAN)),
            Map.entry("sunday", Token.dayName(Weekday.SUNDAY, DUMMY_SPAN)),
            Map.entry("sun", Token.dayName(Weekday.SUNDAY, DUMMY_SPAN)),

            // Month names
            Map.entry("january", Token.monthName(MonthName.JANUARY, DUMMY_SPAN)),
            Map.entry("jan", Token.monthName(MonthName.JANUARY, DUMMY_SPAN)),
            Map.entry("february", Token.monthName(MonthName.FEBRUARY, DUMMY_SPAN)),
            Map.entry("feb", Token.monthName(MonthName.FEBRUARY, DUMMY_SPAN)),
            Map.entry("march", Token.monthName(MonthName.MARCH, DUMMY_SPAN)),
            Map.entry("mar", Token.monthName(MonthName.MARCH, DUMMY_SPAN)),
            Map.entry("april", Token.monthName(MonthName.APRIL, DUMMY_SPAN)),
            Map.entry("apr", Token.monthName(MonthName.APRIL, DUMMY_SPAN)),
            Map.entry("may", Token.monthName(MonthName.MAY, DUMMY_SPAN)),
            Map.entry("june", Token.monthName(MonthName.JUNE, DUMMY_SPAN)),
            Map.entry("jun", Token.monthName(MonthName.JUNE, DUMMY_SPAN)),
            Map.entry("july", Token.monthName(MonthName.JULY, DUMMY_SPAN)),
            Map.entry("jul", Token.monthName(MonthName.JULY, DUMMY_SPAN)),
            Map.entry("august", Token.monthName(MonthName.AUGUST, DUMMY_SPAN)),
            Map.entry("aug", Token.monthName(MonthName.AUGUST, DUMMY_SPAN)),
            Map.entry("september", Token.monthName(MonthName.SEPTEMBER, DUMMY_SPAN)),
            Map.entry("sep", Token.monthName(MonthName.SEPTEMBER, DUMMY_SPAN)),
            Map.entry("october", Token.monthName(MonthName.OCTOBER, DUMMY_SPAN)),
            Map.entry("oct", Token.monthName(MonthName.OCTOBER, DUMMY_SPAN)),
            Map.entry("november", Token.monthName(MonthName.NOVEMBER, DUMMY_SPAN)),
            Map.entry("nov", Token.monthName(MonthName.NOVEMBER, DUMMY_SPAN)),
            Map.entry("december", Token.monthName(MonthName.DECEMBER, DUMMY_SPAN)),
            Map.entry("dec", Token.monthName(MonthName.DECEMBER, DUMMY_SPAN)),

            // Ordinals
            Map.entry("first", Token.ordinal(OrdinalPosition.FIRST, DUMMY_SPAN)),
            Map.entry("second", Token.ordinal(OrdinalPosition.SECOND, DUMMY_SPAN)),
            Map.entry("third", Token.ordinal(OrdinalPosition.THIRD, DUMMY_SPAN)),
            Map.entry("fourth", Token.ordinal(OrdinalPosition.FOURTH, DUMMY_SPAN)),
            Map.entry("fifth", Token.ordinal(OrdinalPosition.FIFTH, DUMMY_SPAN)),

            // Interval units
            Map.entry("min", Token.intervalUnit(IntervalUnit.MINUTES, DUMMY_SPAN)),
            Map.entry("mins", Token.intervalUnit(IntervalUnit.MINUTES, DUMMY_SPAN)),
            Map.entry("minute", Token.intervalUnit(IntervalUnit.MINUTES, DUMMY_SPAN)),
            Map.entry("minutes", Token.intervalUnit(IntervalUnit.MINUTES, DUMMY_SPAN)),
            Map.entry("hour", Token.intervalUnit(IntervalUnit.HOURS, DUMMY_SPAN)),
            Map.entry("hours", Token.intervalUnit(IntervalUnit.HOURS, DUMMY_SPAN)),
            Map.entry("hr", Token.intervalUnit(IntervalUnit.HOURS, DUMMY_SPAN)),
            Map.entry("hrs", Token.intervalUnit(IntervalUnit.HOURS, DUMMY_SPAN)));
  }
}
