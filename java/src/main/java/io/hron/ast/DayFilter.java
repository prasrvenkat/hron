package io.hron.ast;

import java.util.List;

/**
 * Represents a filter for which days a schedule applies to.
 *
 * @param kind the type of day filter
 * @param days the specific days (only used when kind is DAYS)
 */
public record DayFilter(Kind kind, List<Weekday> days) {

  /** The type of day filter. */
  public enum Kind {
    /** Matches every day. */
    EVERY,
    /** Matches weekdays (Monday-Friday). */
    WEEKDAY,
    /** Matches weekend days (Saturday-Sunday). */
    WEEKEND,
    /** Matches specific days of the week. */
    DAYS
  }

  /**
   * Creates a filter that matches every day.
   *
   * @return a new every-day filter
   */
  public static DayFilter every() {
    return new DayFilter(Kind.EVERY, List.of());
  }

  /**
   * Creates a filter that matches weekdays (Mon-Fri).
   *
   * @return a new weekday filter
   */
  public static DayFilter weekday() {
    return new DayFilter(Kind.WEEKDAY, List.of());
  }

  /**
   * Creates a filter that matches weekends (Sat-Sun).
   *
   * @return a new weekend filter
   */
  public static DayFilter weekend() {
    return new DayFilter(Kind.WEEKEND, List.of());
  }

  /**
   * Creates a filter that matches specific days.
   *
   * @param days the days to match
   * @return a new specific-days filter
   */
  public static DayFilter days(List<Weekday> days) {
    return new DayFilter(Kind.DAYS, List.copyOf(days));
  }
}
