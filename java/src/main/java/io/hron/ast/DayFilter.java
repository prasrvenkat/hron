package io.hron.ast;

import java.util.List;

public record DayFilter(Kind kind, List<Weekday> days) {

  public enum Kind {
    EVERY,
    WEEKDAY,
    WEEKEND,
    DAYS
  }

  public static DayFilter every() {
    return new DayFilter(Kind.EVERY, List.of());
  }

  public static DayFilter weekday() {
    return new DayFilter(Kind.WEEKDAY, List.of());
  }

  public static DayFilter weekend() {
    return new DayFilter(Kind.WEEKEND, List.of());
  }

  public static DayFilter days(List<Weekday> days) {
    return new DayFilter(Kind.DAYS, List.copyOf(days));
  }
}
