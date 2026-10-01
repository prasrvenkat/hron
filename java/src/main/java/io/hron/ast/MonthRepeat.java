package io.hron.ast;

import java.util.List;

public record MonthRepeat(int interval, MonthTarget target, List<TimeOfDay> times)
    implements ScheduleExpr {
  public MonthRepeat {
    times = List.copyOf(times);
  }
}
