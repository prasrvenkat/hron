package io.hron.ast;

import java.util.Map;
import java.util.Optional;

/** Represents a day of the week. */
public enum Weekday {
  MONDAY(1, "monday"),
  TUESDAY(2, "tuesday"),
  WEDNESDAY(3, "wednesday"),
  THURSDAY(4, "thursday"),
  FRIDAY(5, "friday"),
  SATURDAY(6, "saturday"),
  SUNDAY(7, "sunday");

  private final int isoNumber;
  private final String displayName;

  Weekday(int isoNumber, String displayName) {
    this.isoNumber = isoNumber;
    this.displayName = displayName;
  }

  /**
   * Returns the ISO 8601 day number (Monday=1, Sunday=7).
   *
   * @return the ISO day number
   */
  public int number() {
    return isoNumber;
  }

  /**
   * Returns the cron day of week number (Sunday=0, Monday=1, ..., Saturday=6).
   *
   * @return the cron day of week number
   */
  public int cronDOW() {
    return switch (this) {
      case SUNDAY -> 0;
      case MONDAY -> 1;
      case TUESDAY -> 2;
      case WEDNESDAY -> 3;
      case THURSDAY -> 4;
      case FRIDAY -> 5;
      case SATURDAY -> 6;
    };
  }

  @Override
  public String toString() {
    return displayName;
  }

  private static final Map<String, Weekday> PARSE_MAP =
      Map.ofEntries(
          Map.entry("monday", MONDAY), Map.entry("mon", MONDAY),
          Map.entry("tuesday", TUESDAY), Map.entry("tue", TUESDAY),
          Map.entry("wednesday", WEDNESDAY), Map.entry("wed", WEDNESDAY),
          Map.entry("thursday", THURSDAY), Map.entry("thu", THURSDAY),
          Map.entry("friday", FRIDAY), Map.entry("fri", FRIDAY),
          Map.entry("saturday", SATURDAY), Map.entry("sat", SATURDAY),
          Map.entry("sunday", SUNDAY), Map.entry("sun", SUNDAY));

  /**
   * Parses a weekday name (case insensitive).
   *
   * @param s the string to parse
   * @return the weekday if valid
   */
  public static Optional<Weekday> parse(String s) {
    return Optional.ofNullable(PARSE_MAP.get(s.toLowerCase()));
  }

  /**
   * Returns a Weekday from an ISO 8601 day number.
   *
   * @param n the ISO day number (1-7)
   * @return the weekday if valid
   */
  public static Optional<Weekday> fromNumber(int n) {
    if (n < 1 || n > 7) {
      return Optional.empty();
    }
    return Optional.of(values()[n - 1]);
  }

  /**
   * Returns a Weekday from a java.time.DayOfWeek.
   *
   * @param dow the DayOfWeek
   * @return the corresponding Weekday
   */
  public static Weekday fromDayOfWeek(java.time.DayOfWeek dow) {
    return values()[dow.getValue() - 1];
  }

  /**
   * Converts this Weekday to a java.time.DayOfWeek.
   *
   * @return the corresponding DayOfWeek
   */
  public java.time.DayOfWeek toDayOfWeek() {
    return java.time.DayOfWeek.of(isoNumber);
  }
}
