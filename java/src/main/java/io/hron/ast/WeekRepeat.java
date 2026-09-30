package io.hron.ast;

import java.util.List;

/**
 * An expression that fires on named days of the week, every week or every N weeks.
 *
 * @param interval the number of weeks between occurrences
 * @param weekDays the days of the week to fire
 * @param times the times of day to fire
 */
public record WeekRepeat(int interval, List<Weekday> weekDays, List<TimeOfDay> times)
    implements ScheduleExpr {
  public WeekRepeat {
    weekDays = List.copyOf(weekDays);
    times = List.copyOf(times);
  }
}
