package io.hron.ast;

import java.util.ArrayList;
import java.util.List;

public record DayOfMonthSpec(Kind kind, int day, int start, int end) {

  public enum Kind {
    SINGLE,
    RANGE
  }

  public static DayOfMonthSpec single(int day) {
    return new DayOfMonthSpec(Kind.SINGLE, day, 0, 0);
  }

  public static DayOfMonthSpec range(int start, int end) {
    return new DayOfMonthSpec(Kind.RANGE, 0, start, end);
  }

  public List<Integer> expand() {
    if (kind == Kind.SINGLE) {
      return List.of(day);
    }
    List<Integer> days = new ArrayList<>(Math.max(end - start + 1, 0));
    for (int i = start; i <= end; i++) {
      days.add(i);
    }
    return days;
  }
}
