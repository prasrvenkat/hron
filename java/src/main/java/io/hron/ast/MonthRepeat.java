package io.hron.ast;

import java.util.List;

/**
 * A month-based repeat expression like "every month on the 1st at 9:00".
 *
 * @param interval the number of months between occurrences (1 for every month)
 * @param target the day(s) within the month to fire
 * @param times the times of day to fire
 */
public record MonthRepeat(int interval, MonthTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  /** Creates a new MonthRepeat with defensive copy of times list. */
  public MonthRepeat {
    times = List.copyOf(times);
  }
}
