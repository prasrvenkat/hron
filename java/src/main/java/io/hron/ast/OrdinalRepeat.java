package io.hron.ast;

import java.util.List;

/**
 * An ordinal-based repeat expression like "first monday of every month at 10:00".
 *
 * @param interval the number of months between occurrences (1 for every month)
 * @param ordinal the ordinal position (first, second, ..., last)
 * @param weekday the day of the week
 * @param times the times of day to fire
 */
public record OrdinalRepeat(
    int interval, OrdinalPosition ordinal, Weekday weekday, List<TimeOfDay> times)
    implements ScheduleExpr {
  /** Creates a new OrdinalRepeat with defensive copy of times list. */
  public OrdinalRepeat {
    times = List.copyOf(times);
  }
}
