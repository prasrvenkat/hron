package io.hron.eval;

import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;

/** An occurrence a search found, with the date it is scheduled on. */
record Occurrence(ZonedDateTime instant, LocalDate date) {
  /**
   * How many dates past its scheduled date an occurrence can land: a fixed time shifted out of a
   * gap before midnight lands on the next date.
   */
  static final long MAX_SHIFT_DAYS = 1;

  /**
   * Whether an occurrence scheduled on {@code date} can precede, in {@code direction}, the best
   * one, scheduled on {@code best}, given that each lands at most MAX_SHIFT_DAYS after its date.
   */
  static boolean couldBeat(LocalDate date, LocalDate best, Direction direction) {
    return direction.sign() * ChronoUnit.DAYS.between(best, date) <= MAX_SHIFT_DAYS;
  }
}
