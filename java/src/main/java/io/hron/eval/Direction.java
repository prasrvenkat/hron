package io.hron.eval;

import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.util.List;

/** The direction a search moves in time. */
enum Direction {
  FORWARD,
  BACKWARD;

  long sign() {
    return this == FORWARD ? 1 : -1;
  }

  /** Whether {@code a} comes before {@code b} in this direction. */
  boolean precedes(LocalDate a, LocalDate b) {
    return this == FORWARD ? a.isBefore(b) : a.isAfter(b);
  }

  /** Whether instant {@code a} comes before instant {@code b} in this direction. */
  boolean precedes(ZonedDateTime a, ZonedDateTime b) {
    return this == FORWARD ? a.isBefore(b) : a.isAfter(b);
  }

  /** {@code items}, given earliest first, in this direction's order. */
  <T> List<T> inOrder(List<T> items) {
    return this == FORWARD ? items : items.reversed();
  }
}
