package io.hron.ast;

import java.util.List;

/**
 * A year-based repeat expression like "every year on dec 25 at 00:00".
 *
 * @param interval the number of years between occurrences (1 for every year)
 * @param target the day within the year to fire
 * @param times the times of day to fire
 */
public record YearRepeat(int interval, YearTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  /** Creates a new YearRepeat with defensive copy of times list. */
  public YearRepeat {
    times = List.copyOf(times);
  }
}
