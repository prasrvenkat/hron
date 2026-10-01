package io.hron.eval;

import java.time.LocalDate;
import java.time.ZonedDateTime;
import java.util.List;

enum Direction {
  FORWARD,
  BACKWARD;

  long sign() {
    return this == FORWARD ? 1 : -1;
  }

  boolean precedes(LocalDate a, LocalDate b) {
    return this == FORWARD ? a.isBefore(b) : a.isAfter(b);
  }

  boolean precedes(ZonedDateTime a, ZonedDateTime b) {
    return this == FORWARD ? a.isBefore(b) : a.isAfter(b);
  }

  <T> List<T> inOrder(List<T> items) {
    return this == FORWARD ? items : items.reversed();
  }
}
