package io.hron.ast;

import java.util.ArrayList;
import java.util.List;

/**
 * Represents which day(s) within a month a schedule fires on.
 *
 * @param kind the type of month target
 * @param specs the day specifications (only used when kind is DAYS)
 * @param nearestWeekdayDay the target day for nearest weekday (only used when kind is
 *     NEAREST_WEEKDAY)
 * @param nearestDirection the direction for nearest weekday (only used when kind is
 *     NEAREST_WEEKDAY, may be null for standard cron W behavior)
 */
public record MonthTarget(
    Kind kind,
    List<DayOfMonthSpec> specs,
    int nearestWeekdayDay,
    NearestDirection nearestDirection) {

  /** The type of month target. */
  public enum Kind {
    /** Specific days of the month. */
    DAYS,
    /** The last day of the month. */
    LAST_DAY,
    /** The last weekday (Mon-Fri) of the month. */
    LAST_WEEKDAY,
    /**
     * Nearest weekday to a given day of month. Standard (no direction): never crosses month
     * boundary (cron W compatibility). Directional (with direction): can cross month boundary.
     */
    NEAREST_WEEKDAY
  }

  /**
   * Creates a month target for specific days.
   *
   * @param specs the day specifications
   * @return a new days target
   */
  public static MonthTarget days(List<DayOfMonthSpec> specs) {
    return new MonthTarget(Kind.DAYS, List.copyOf(specs), 0, null);
  }

  /**
   * Creates a month target for the last day of the month.
   *
   * @return a new last-day target
   */
  public static MonthTarget lastDay() {
    return new MonthTarget(Kind.LAST_DAY, List.of(), 0, null);
  }

  /**
   * Creates a month target for the last weekday of the month.
   *
   * @return a new last-weekday target
   */
  public static MonthTarget lastWeekday() {
    return new MonthTarget(Kind.LAST_WEEKDAY, List.of(), 0, null);
  }

  /**
   * Creates a month target for the nearest weekday to a specific day. Standard behavior (no
   * direction): never crosses month boundary (cron W compatibility).
   *
   * @param day the target day (1-31)
   * @return a new nearest-weekday target
   */
  public static MonthTarget nearestWeekday(int day) {
    return new MonthTarget(Kind.NEAREST_WEEKDAY, List.of(), day, null);
  }

  /**
   * Creates a month target for the nearest weekday to a specific day with a direction.
   *
   * @param day the target day (1-31)
   * @param direction the direction (NEXT or PREVIOUS), may be null for standard behavior
   * @return a new nearest-weekday target
   */
  public static MonthTarget nearestWeekday(int day, NearestDirection direction) {
    return new MonthTarget(Kind.NEAREST_WEEKDAY, List.of(), day, direction);
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
