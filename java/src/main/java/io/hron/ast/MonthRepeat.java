package io.hron.ast;

import java.util.List;

/**
 * An expression that fires on certain days of the month, every month or every N months.
 *
 * @param interval the number of months between occurrences (1 for every month)
 * @param target the day(s) within the month to fire
 * @param times the times of day to fire
 */
public record MonthRepeat(int interval, MonthTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  public MonthRepeat {
    times = List.copyOf(times);
  }
}
