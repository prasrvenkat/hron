package io.hron.ast;

import java.util.ArrayList;
import java.util.List;

/**
 * Represents a single day or range of days within a month.
 *
 * @param kind the type of specification
 * @param day the day (for SINGLE)
 * @param start the start day (for RANGE)
 * @param end the end day (for RANGE)
 */
public record DayOfMonthSpec(Kind kind, int day, int start, int end) {

  /** The type of day-of-month specification. */
  public enum Kind {
    /** A single day. */
    SINGLE,
    /** A range of days. */
    RANGE
  }

  /**
   * Creates a single day specification.
   *
   * @param day the day number
   * @return a new single day specification
   */
  public static DayOfMonthSpec single(int day) {
    return new DayOfMonthSpec(Kind.SINGLE, day, 0, 0);
  }

  /**
   * Creates a day range specification.
   *
   * @param start the start day
   * @param end the end day
   * @return a new day range specification
   */
  public static DayOfMonthSpec range(int start, int end) {
    return new DayOfMonthSpec(Kind.RANGE, 0, start, end);
  }

  /**
   * Returns all days in this specification.
   *
   * @return a list of all days covered by this specification
   */
  public List<Integer> expand() {
    if (kind == Kind.SINGLE) {
      return List.of(day);
    }
    List<Integer> days = new ArrayList<>(end - start + 1);
    for (int i = start; i <= end; i++) {
      days.add(i);
    }
    return days;
  }
}
