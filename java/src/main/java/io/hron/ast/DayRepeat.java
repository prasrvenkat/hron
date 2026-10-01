package io.hron.ast;

import java.util.List;

public record DayRepeat(int interval, DayFilter days, List<TimeOfDay> times)
    implements ScheduleExpr {
  public DayRepeat {
    times = List.copyOf(times);
  }
}
