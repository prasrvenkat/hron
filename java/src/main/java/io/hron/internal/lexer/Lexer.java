package io.hron.internal.lexer;

import io.hron.HronException;
import io.hron.Span;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class Lexer {
  private static final int MAX_NUMBER = Integer.MAX_VALUE;

  private final String input;
  private int pos;

  private Lexer(String input) {
    this.input = input;
  }

  public static List<Token> tokenize(String input) throws HronException {
    return new Lexer(input).tokenize();
  }

  /**
   * Converts a range of UTF-16 offsets into {@code input} to the code-point span errors report. A
   * lone surrogate counts as one code point.
   */
  public static Span span(String input, int start, int end) {
    int startCodePoints = input.codePointCount(0, start);
    return new Span(startCodePoints, startCodePoints + input.codePointCount(start, end));
  }

  private List<Token> tokenize() throws HronException {
    List<Token> tokens = new ArrayList<>();
    while (true) {
      advanceWhile(Lexer::isWhitespace);
      if (pos >= input.length()) {
        return tokens;
      }
      int start = pos;
      char c = input.charAt(pos);
      Token token;
      if (!tokens.isEmpty() && tokens.getLast().kind() == TokenKind.IN) {
        advanceWhile(b -> !isWhitespace(b));
        token = Token.keyword(TokenKind.TIMEZONE);
      } else if (c == ',') {
        pos++;
        token = Token.keyword(TokenKind.COMMA);
      } else if (isAsciiLetter(c)) {
        token = word(start);
      } else if (isAsciiDigit(c)) {
        token = digits(start);
      } else {
        throw unexpectedCharacter(start);
      }
      tokens.add(token.at(start, pos));
    }
  }

  private interface CharTest {
    boolean test(char c);
  }

  private void advanceWhile(CharTest matches) {
    while (pos < input.length() && matches.test(input.charAt(pos))) {
      pos++;
    }
  }

  private boolean restStartsWith(char c) {
    return pos < input.length() && input.charAt(pos) == c;
  }

  private HronException error(String message, int start) {
    return HronException.lex(message, span(input, start, pos), input);
  }

  private Token word(int start) throws HronException {
    advanceWhile(c -> isAsciiLetter(c) || isAsciiDigit(c) || c == '_');
    String text = input.substring(start, pos);
    Token keyword = KEYWORDS.get(asciiLowercase(text));
    if (keyword == null) {
      throw error("unknown keyword '" + text + "'", start);
    }
    return keyword;
  }

  private Token digits(int start) throws HronException {
    advanceWhile(Lexer::isAsciiDigit);
    String digits = input.substring(start, pos);
    if (digits.length() == 4 && isIsoDateTail()) {
      pos += "-MM-DD".length();
      return Token.keyword(TokenKind.ISO_DATE);
    }
    if (restStartsWith(':')) {
      return time(start);
    }
    long value = numberValue(digits);
    if (value > MAX_NUMBER) {
      throw error("number must be at most 2147483647", start);
    }
    if (pos + 2 <= input.length()) {
      String suffix = asciiLowercase(input.substring(pos, pos + 2));
      if (suffix.equals("st")
          || suffix.equals("nd")
          || suffix.equals("rd")
          || suffix.equals("th")) {
        pos += 2;
        return Token.number(TokenKind.ORDINAL_NUMBER, (int) value);
      }
    }
    return Token.number(TokenKind.NUMBER, (int) value);
  }

  private Token time(int start) throws HronException {
    int colon = pos;
    pos++;
    advanceWhile(Lexer::isAsciiDigit);
    String hour = input.substring(start, colon);
    String minute = input.substring(colon + 1, pos);
    String text = input.substring(start, pos);
    if (hour.length() > 2 || minute.length() != 2) {
      throw error("time must be H:MM or HH:MM, got " + text, start);
    }
    int h = (int) numberValue(hour);
    int m = (int) numberValue(minute);
    if (h > 23 || m > 59) {
      throw error("time must be 00:00-23:59, got " + text, start);
    }
    return Token.time(h, m);
  }

  private HronException unexpectedCharacter(int start) {
    int c = input.codePointAt(start);
    // `'` is excluded because `'''` would not read as a quoted character.
    String shown =
        c >= '!' && c <= '~' && c != '\''
            ? "'" + (char) c + "'"
            : String.format(Locale.ROOT, "U+%04X", c);
    Span span = span(input, start, start + Character.charCount(c));
    return HronException.lex("unexpected character " + shown, span, input);
  }

  private boolean isIsoDateTail() {
    if (pos + 6 > input.length()) {
      return false;
    }
    return input.charAt(pos) == '-'
        && isAsciiDigit(input.charAt(pos + 1))
        && isAsciiDigit(input.charAt(pos + 2))
        && input.charAt(pos + 3) == '-'
        && isAsciiDigit(input.charAt(pos + 4))
        && isAsciiDigit(input.charAt(pos + 5));
  }

  /** Stops at the first value above MAX_NUMBER, so a run of any length cannot overflow. */
  private static long numberValue(String digits) {
    long n = 0;
    for (int i = 0; i < digits.length(); i++) {
      n = n * 10 + (digits.charAt(i) - '0');
      if (n > MAX_NUMBER) {
        return n;
      }
    }
    return n;
  }

  /**
   * {@code String.toLowerCase} follows the default locale, which in Turkish maps I to dotless ı.
   */
  private static String asciiLowercase(String s) {
    StringBuilder out = new StringBuilder(s.length());
    for (int i = 0; i < s.length(); i++) {
      char c = s.charAt(i);
      out.append(c >= 'A' && c <= 'Z' ? (char) (c + ('a' - 'A')) : c);
    }
    return out.toString();
  }

  private static boolean isAsciiDigit(char c) {
    return c >= '0' && c <= '9';
  }

  private static boolean isAsciiLetter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
  }

  /** Only these four separate tokens; any other whitespace is an unexpected character. */
  private static boolean isWhitespace(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
  }

  private static final Map<String, Token> KEYWORDS;

  static {
    KEYWORDS =
        Map.ofEntries(
            Map.entry("every", Token.keyword(TokenKind.EVERY)),
            Map.entry("on", Token.keyword(TokenKind.ON)),
            Map.entry("at", Token.keyword(TokenKind.AT)),
            Map.entry("from", Token.keyword(TokenKind.FROM)),
            Map.entry("to", Token.keyword(TokenKind.TO)),
            Map.entry("in", Token.keyword(TokenKind.IN)),
            Map.entry("of", Token.keyword(TokenKind.OF)),
            Map.entry("the", Token.keyword(TokenKind.THE)),
            Map.entry("last", Token.keyword(TokenKind.LAST)),
            Map.entry("except", Token.keyword(TokenKind.EXCEPT)),
            Map.entry("until", Token.keyword(TokenKind.UNTIL)),
            Map.entry("starting", Token.keyword(TokenKind.STARTING)),
            Map.entry("during", Token.keyword(TokenKind.DURING)),
            Map.entry("year", Token.keyword(TokenKind.YEAR)),
            Map.entry("years", Token.keyword(TokenKind.YEAR)),
            Map.entry("day", Token.keyword(TokenKind.DAY)),
            Map.entry("days", Token.keyword(TokenKind.DAY)),
            Map.entry("weekday", Token.keyword(TokenKind.WEEKDAY)),
            Map.entry("weekdays", Token.keyword(TokenKind.WEEKDAY)),
            Map.entry("weekend", Token.keyword(TokenKind.WEEKEND)),
            Map.entry("weekends", Token.keyword(TokenKind.WEEKEND)),
            Map.entry("weeks", Token.keyword(TokenKind.WEEKS)),
            Map.entry("week", Token.keyword(TokenKind.WEEKS)),
            Map.entry("month", Token.keyword(TokenKind.MONTH)),
            Map.entry("months", Token.keyword(TokenKind.MONTH)),
            Map.entry("nearest", Token.keyword(TokenKind.NEAREST)),
            Map.entry("next", Token.keyword(TokenKind.NEXT)),
            Map.entry("previous", Token.keyword(TokenKind.PREVIOUS)),
            Map.entry("monday", Token.dayName(Weekday.MONDAY)),
            Map.entry("mon", Token.dayName(Weekday.MONDAY)),
            Map.entry("tuesday", Token.dayName(Weekday.TUESDAY)),
            Map.entry("tue", Token.dayName(Weekday.TUESDAY)),
            Map.entry("wednesday", Token.dayName(Weekday.WEDNESDAY)),
            Map.entry("wed", Token.dayName(Weekday.WEDNESDAY)),
            Map.entry("thursday", Token.dayName(Weekday.THURSDAY)),
            Map.entry("thu", Token.dayName(Weekday.THURSDAY)),
            Map.entry("friday", Token.dayName(Weekday.FRIDAY)),
            Map.entry("fri", Token.dayName(Weekday.FRIDAY)),
            Map.entry("saturday", Token.dayName(Weekday.SATURDAY)),
            Map.entry("sat", Token.dayName(Weekday.SATURDAY)),
            Map.entry("sunday", Token.dayName(Weekday.SUNDAY)),
            Map.entry("sun", Token.dayName(Weekday.SUNDAY)),
            Map.entry("january", Token.monthName(MonthName.JANUARY)),
            Map.entry("jan", Token.monthName(MonthName.JANUARY)),
            Map.entry("february", Token.monthName(MonthName.FEBRUARY)),
            Map.entry("feb", Token.monthName(MonthName.FEBRUARY)),
            Map.entry("march", Token.monthName(MonthName.MARCH)),
            Map.entry("mar", Token.monthName(MonthName.MARCH)),
            Map.entry("april", Token.monthName(MonthName.APRIL)),
            Map.entry("apr", Token.monthName(MonthName.APRIL)),
            Map.entry("may", Token.monthName(MonthName.MAY)),
            Map.entry("june", Token.monthName(MonthName.JUNE)),
            Map.entry("jun", Token.monthName(MonthName.JUNE)),
            Map.entry("july", Token.monthName(MonthName.JULY)),
            Map.entry("jul", Token.monthName(MonthName.JULY)),
            Map.entry("august", Token.monthName(MonthName.AUGUST)),
            Map.entry("aug", Token.monthName(MonthName.AUGUST)),
            Map.entry("september", Token.monthName(MonthName.SEPTEMBER)),
            Map.entry("sep", Token.monthName(MonthName.SEPTEMBER)),
            Map.entry("october", Token.monthName(MonthName.OCTOBER)),
            Map.entry("oct", Token.monthName(MonthName.OCTOBER)),
            Map.entry("november", Token.monthName(MonthName.NOVEMBER)),
            Map.entry("nov", Token.monthName(MonthName.NOVEMBER)),
            Map.entry("december", Token.monthName(MonthName.DECEMBER)),
            Map.entry("dec", Token.monthName(MonthName.DECEMBER)),
            Map.entry("first", Token.ordinal(OrdinalPosition.FIRST)),
            Map.entry("second", Token.ordinal(OrdinalPosition.SECOND)),
            Map.entry("third", Token.ordinal(OrdinalPosition.THIRD)),
            Map.entry("fourth", Token.ordinal(OrdinalPosition.FOURTH)),
            Map.entry("fifth", Token.ordinal(OrdinalPosition.FIFTH)),
            Map.entry("min", Token.intervalUnit(IntervalUnit.MINUTES)),
            Map.entry("mins", Token.intervalUnit(IntervalUnit.MINUTES)),
            Map.entry("minute", Token.intervalUnit(IntervalUnit.MINUTES)),
            Map.entry("minutes", Token.intervalUnit(IntervalUnit.MINUTES)),
            Map.entry("hour", Token.intervalUnit(IntervalUnit.HOURS)),
            Map.entry("hours", Token.intervalUnit(IntervalUnit.HOURS)),
            Map.entry("hr", Token.intervalUnit(IntervalUnit.HOURS)),
            Map.entry("hrs", Token.intervalUnit(IntervalUnit.HOURS)));
  }
}
