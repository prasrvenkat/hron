package io.hron.eval;

import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;

/**
 * {@link #couldBeat} and {@link #isBehind} rest on one fact: an occurrence lands on a first pass,
 * from its scheduled date to {@code shift} dates after it ({@link DailyTimes#maxShiftDays}), and
 * first passes keep wall-clock order.
 */
record Occurrence(ZonedDateTime instant, LocalDate landing) {
  /**
   * How many dates behind a date that has begun now's wall date can read: from the second pass of a
   * fall-back overlap that crosses midnight, one.
   */
  static final long MAX_OVERLAP_DAYS = 1;

  static boolean couldBeat(LocalDate date, LocalDate landing, Direction direction, long shift) {
    return switch (direction) {
      case FORWARD -> !date.isAfter(landing);
      case BACKWARD -> ChronoUnit.DAYS.between(date, landing) <= shift;
    };
  }

  static boolean isBehind(LocalDate date, LocalDate nowDate, Direction direction, long shift) {
    return switch (direction) {
      case FORWARD -> ChronoUnit.DAYS.between(date, nowDate) > shift;
      case BACKWARD -> ChronoUnit.DAYS.between(nowDate, date) > MAX_OVERLAP_DAYS;
    };
  }
}
