package io.hron.ast;

import java.util.ArrayList;
import java.util.List;

/**
 * @param specs only used when kind is DAYS
 * @param nearestWeekdayDay only used when kind is NEAREST_WEEKDAY
 * @param nearestDirection only used when kind is NEAREST_WEEKDAY; a null nearestDirection stays in
 *     the month, as cron W does; a direction can cross into the adjacent month
 * @param ordinal only used when kind is ORDINAL_WEEKDAY
 * @param weekday only used when kind is ORDINAL_WEEKDAY
 */
public record MonthTarget(
    Kind kind,
    List<DayOfMonthSpec> specs,
    int nearestWeekdayDay,
    NearestDirection nearestDirection,
    OrdinalPosition ordinal,
    Weekday weekday) {

  public enum Kind {
    DAYS,
    LAST_DAY,
    LAST_WEEKDAY,
    NEAREST_WEEKDAY,
    ORDINAL_WEEKDAY
  }

  public static MonthTarget days(List<DayOfMonthSpec> specs) {
    return new MonthTarget(Kind.DAYS, List.copyOf(specs), 0, null, null, null);
  }

  public static MonthTarget lastDay() {
    return new MonthTarget(Kind.LAST_DAY, List.of(), 0, null, null, null);
  }

  public static MonthTarget lastWeekday() {
    return new MonthTarget(Kind.LAST_WEEKDAY, List.of(), 0, null, null, null);
  }

  public static MonthTarget nearestWeekday(int day) {
    return new MonthTarget(Kind.NEAREST_WEEKDAY, List.of(), day, null, null, null);
  }

  public static MonthTarget nearestWeekday(int day, NearestDirection direction) {
    return new MonthTarget(Kind.NEAREST_WEEKDAY, List.of(), day, direction, null, null);
  }

  public static MonthTarget ordinalWeekday(OrdinalPosition ordinal, Weekday weekday) {
    return new MonthTarget(Kind.ORDINAL_WEEKDAY, List.of(), 0, null, ordinal, weekday);
  }

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
