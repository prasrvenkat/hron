package io.hron.ast;

import java.util.List;

/**
 * A day-based repeat expression like "every day at 9:00" or "every 3 days at 09:00".
 *
 * @param interval the number of days between occurrences (1 for every day)
 * @param days the day filter (every, weekday, weekend, or specific days)
 * @param times the times of day to fire
 */
public record DayRepeat(int interval, DayFilter days, List<TimeOfDay> times)
    implements ScheduleExpr {
  /** Creates a new DayRepeat with defensive copy of times list. */
  public DayRepeat {
    times = List.copyOf(times);
  }
}
