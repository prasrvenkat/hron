package io.hron.ast;

import java.util.List;

public record YearRepeat(int interval, YearTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  public YearRepeat {
    times = List.copyOf(times);
  }
}
