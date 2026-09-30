package io.hron.ast;

import java.util.List;

/**
 * An expression that fires on one date.
 *
 * @param dateSpec the date specification
 * @param times the times of day to fire
 */
public record SingleDate(DateSpec dateSpec, List<TimeOfDay> times) implements ScheduleExpr {
  public SingleDate {
    times = List.copyOf(times);
  }
}
