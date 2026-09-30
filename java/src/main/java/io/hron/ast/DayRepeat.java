package io.hron.ast;

import java.util.List;

/**
 * An expression that fires every day or every N days, optionally only on certain days.
 *
 * @param interval the number of days between occurrences (1 for every day)
 * @param days the day filter (every, weekday, weekend, or specific days)
 * @param times the times of day to fire
 */
public record DayRepeat(int interval, DayFilter days, List<TimeOfDay> times)
    implements ScheduleExpr {
  public DayRepeat {
    times = List.copyOf(times);
  }
}
