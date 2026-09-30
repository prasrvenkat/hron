package io.hron.ast;

import java.util.List;

/**
 * Represents a filter for which days a schedule applies to.
 *
 * @param kind the type of day filter
 * @param days the specific days (only used when kind is DAYS)
 */
public record DayFilter(Kind kind, List<Weekday> days) {

  public enum Kind {
    EVERY,
    /** Matches weekdays (Monday-Friday). */
    WEEKDAY,
    /** Matches weekend days (Saturday-Sunday). */
    WEEKEND,
    DAYS
  }

  public static DayFilter every() {
    return new DayFilter(Kind.EVERY, List.of());
  }

  public static DayFilter weekday() {
    return new DayFilter(Kind.WEEKDAY, List.of());
  }

  public static DayFilter weekend() {
    return new DayFilter(Kind.WEEKEND, List.of());
  }

  public static DayFilter days(List<Weekday> days) {
    return new DayFilter(Kind.DAYS, List.copyOf(days));
  }
}
