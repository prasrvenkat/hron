package io.hron.ast;

import java.util.ArrayList;
import java.util.List;

/**
 * Represents which day(s) within a month a schedule fires on.
 *
 * @param kind the type of month target
 * @param specs the day specifications (only used when kind is DAYS)
 */
public record MonthTarget(Kind kind, List<DayOfMonthSpec> specs) {

  /** The type of month target. */
  public enum Kind {
    /** Specific days of the month. */
    DAYS,
    /** The last day of the month. */
    LAST_DAY,
    /** The last weekday (Mon-Fri) of the month. */
    LAST_WEEKDAY
  }

  /**
   * Creates a month target for specific days.
   *
   * @param specs the day specifications
   * @return a new days target
   */
  public static MonthTarget days(List<DayOfMonthSpec> specs) {
    return new MonthTarget(Kind.DAYS, List.copyOf(specs));
  }

  /**
   * Creates a month target for the last day of the month.
   *
   * @return a new last-day target
   */
  public static MonthTarget lastDay() {
    return new MonthTarget(Kind.LAST_DAY, List.of());
  }

  /**
   * Creates a month target for the last weekday of the month.
   *
   * @return a new last-weekday target
   */
  public static MonthTarget lastWeekday() {
    return new MonthTarget(Kind.LAST_WEEKDAY, List.of());
  }

  /**
   * Returns all days specified by this target (for DAYS kind only).
   *
   * @return a list of all days
   */
  public List<Integer> expandDays() {
    if (kind != Kind.DAYS) {
      return List.of();
    }
    List<Integer> days = new ArrayList<>();
    for (DayOfMonthSpec spec : specs) {
      days.addAll(spec.expand());
    }
    return days;
  }
}
