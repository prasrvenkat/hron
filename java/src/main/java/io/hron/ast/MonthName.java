package io.hron.ast;

import java.util.Map;
import java.util.Optional;

/** Represents a month of the year. */
public enum MonthName {
  /** January. */
  JANUARY(1, "jan"),
  /** February. */
  FEBRUARY(2, "feb"),
  /** March. */
  MARCH(3, "mar"),
  /** April. */
  APRIL(4, "apr"),
  /** May. */
  MAY(5, "may"),
  /** June. */
  JUNE(6, "jun"),
  /** July. */
  JULY(7, "jul"),
  /** August. */
  AUGUST(8, "aug"),
  /** September. */
  SEPTEMBER(9, "sep"),
  /** October. */
  OCTOBER(10, "oct"),
  /** November. */
  NOVEMBER(11, "nov"),
  /** December. */
  DECEMBER(12, "dec");

  private final int monthNumber;
  private final String displayName;

  MonthName(int monthNumber, String displayName) {
    this.monthNumber = monthNumber;
    this.displayName = displayName;
  }

  /**
   * Returns the month number (January=1, December=12).
   *
   * @return the month number
   */
  public int number() {
    return monthNumber;
  }

  @Override
  public String toString() {
    return displayName;
  }

  private static final Map<String, MonthName> PARSE_MAP =
      Map.ofEntries(
          Map.entry("january", JANUARY),
          Map.entry("jan", JANUARY),
          Map.entry("february", FEBRUARY),
          Map.entry("feb", FEBRUARY),
          Map.entry("march", MARCH),
          Map.entry("mar", MARCH),
          Map.entry("april", APRIL),
          Map.entry("apr", APRIL),
          Map.entry("may", MAY),
          Map.entry("june", JUNE),
          Map.entry("jun", JUNE),
          Map.entry("july", JULY),
          Map.entry("jul", JULY),
          Map.entry("august", AUGUST),
          Map.entry("aug", AUGUST),
          Map.entry("september", SEPTEMBER),
          Map.entry("sep", SEPTEMBER),
          Map.entry("october", OCTOBER),
          Map.entry("oct", OCTOBER),
          Map.entry("november", NOVEMBER),
          Map.entry("nov", NOVEMBER),
          Map.entry("december", DECEMBER),
          Map.entry("dec", DECEMBER));

  /**
   * Parses a month name (case insensitive).
   *
   * @param s the string to parse
   * @return the month if valid
   */
  public static Optional<MonthName> parse(String s) {
    return Optional.ofNullable(PARSE_MAP.get(s.toLowerCase()));
  }

  /**
   * Returns a MonthName from a java.time.Month.
   *
   * @param month the Month
   * @return the corresponding MonthName
   */
  public static MonthName fromMonth(java.time.Month month) {
    return values()[month.getValue() - 1];
  }

  /**
   * Converts this MonthName to a java.time.Month.
   *
   * @return the corresponding Month
   */
  public java.time.Month toMonth() {
    return java.time.Month.of(monthNumber);
  }
}
