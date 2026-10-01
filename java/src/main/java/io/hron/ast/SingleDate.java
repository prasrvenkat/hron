package io.hron.ast;

import java.util.List;

public record SingleDate(DateSpec dateSpec, List<TimeOfDay> times) implements ScheduleExpr {
  public SingleDate {
    times = List.copyOf(times);
  }
}
