package io.hron.eval;

import java.util.List;

/** The direction a search moves in time. */
enum Direction {
  FORWARD,
  BACKWARD;

  long sign() {
    return this == FORWARD ? 1 : -1;
  }

  /** Whether {@code a} comes before {@code b} in this direction. */
  <T extends Comparable<? super T>> boolean precedes(T a, T b) {
    return this == FORWARD ? a.compareTo(b) < 0 : a.compareTo(b) > 0;
  }

  /** {@code items}, given earliest first, in this direction's order. */
  <T> List<T> inOrder(List<T> items) {
    return this == FORWARD ? items : items.reversed();
  }
}
