package io.hron.internal.eval;

import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.MonthRepeat;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.TimeOfDay;
import io.hron.ast.WeekRepeat;
import io.hron.ast.YearRepeat;
import java.time.LocalTime;
import java.util.List;

sealed interface DailyTimes {
  /**
   * How many dates past its scheduled date a fixed time can land: one shifted out of a gap before
   * midnight lands on the next date.
   */
  long MAX_SHIFT_DAYS = 1;

  record Fixed(List<LocalTime> times) implements DailyTimes {}

  /** An int array keeps the binary search over the slots free of boxing. */
  record Slots(int[] minutes) implements DailyTimes {}

  /**
   * How many dates past its scheduled date an occurrence can land: a gap pushes a fixed time
   * forward, and skips a slot.
   */
  default long maxShiftDays() {
    return switch (this) {
      case Fixed _ -> MAX_SHIFT_DAYS;
      case Slots _ -> 0;
    };
  }

  static DailyTimes of(ScheduleExpr expr) {
    return switch (expr) {
      case IntervalRepeat ir -> new Slots(Evaluator.intervalSlots(ir));
      case DayRepeat dr -> fixed(dr.times());
      case WeekRepeat wr -> fixed(wr.times());
      case MonthRepeat mr -> fixed(mr.times());
      case SingleDate sd -> fixed(sd.times());
      case YearRepeat yr -> fixed(yr.times());
    };
  }

  private static Fixed fixed(List<TimeOfDay> times) {
    return new Fixed(times.stream().map(time -> LocalTime.of(time.hour(), time.minute())).toList());
  }
}
