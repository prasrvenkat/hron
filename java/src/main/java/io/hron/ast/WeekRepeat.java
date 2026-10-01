package io.hron.ast;

import java.util.List;

public record WeekRepeat(int interval, List<Weekday> weekDays, List<TimeOfDay> times)
    implements ScheduleExpr {
  public WeekRepeat {
    weekDays = List.copyOf(weekDays);
    times = List.copyOf(times);
  }
}
