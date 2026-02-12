package io.hron.ast;

import java.util.List;

/**
 * A single-date expression like "on feb 14 at 9:00" or "on 2026-03-15 at 14:30".
 *
 * @param dateSpec the date specification
 * @param times the times of day to fire
 */
public record SingleDate(DateSpec dateSpec, List<TimeOfDay> times) implements ScheduleExpr {
  /** Creates a new SingleDate with defensive copy of times list. */
  public SingleDate {
    times = List.copyOf(times);
  }
}
