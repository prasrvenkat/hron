package io.hron.ast;

import java.util.List;

/**
 * An expression that fires on one day of the year, every year or every N years.
 *
 * @param interval the number of years between occurrences (1 for every year)
 * @param target the day within the year to fire
 * @param times the times of day to fire
 */
public record YearRepeat(int interval, YearTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  public YearRepeat {
    times = List.copyOf(times);
  }
}
