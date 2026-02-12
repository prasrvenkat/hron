package io.hron.ast;

import java.util.List;

/**
 * A week-based repeat expression like "every 2 weeks on monday at 9:00".
 *
 * @param interval the number of weeks between occurrences
 * @param weekDays the days of the week to fire
 * @param times the times of day to fire
 */
public record WeekRepeat(int interval, List<Weekday> weekDays, List<TimeOfDay> times)
    implements ScheduleExpr {
  /** Creates a new WeekRepeat with defensive copy of lists. */
  public WeekRepeat {
    weekDays = List.copyOf(weekDays);
    times = List.copyOf(times);
  }
}
