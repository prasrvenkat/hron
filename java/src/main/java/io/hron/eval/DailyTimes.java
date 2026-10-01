package io.hron.eval;

import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthRepeat;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.TimeOfDay;
import io.hron.ast.WeekRepeat;
import io.hron.ast.YearRepeat;
import java.time.LocalTime;
import java.util.List;

/** The times of day an expression fires at. */
sealed interface DailyTimes {
  /** Fixed times, each shifted out of a gap. */
  record Fixed(List<LocalTime> times) implements DailyTimes {}

  /**
   * Interval slots in minutes after midnight, earliest first, each skipped in a gap. An int array
   * keeps the binary search over them free of boxing.
   */
  record Slots(int[] minutes) implements DailyTimes {}

  static DailyTimes of(ScheduleExpr expr) {
    return switch (expr) {
      case IntervalRepeat ir -> new Slots(intervalSlots(ir));
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

  /** Wall-clock minutes of the slots {@code from + k × interval} up to and including {@code to}. */
  private static int[] intervalSlots(IntervalRepeat ir) {
    long minutesPerUnit = ir.unit() == IntervalUnit.HOURS ? WallClock.MINUTES_PER_HOUR : 1;
    long step = Math.max(ir.interval(), 1) * minutesPerUnit;
    int from = ir.fromTime().totalMinutes();
    int to = ir.toTime().totalMinutes();
    if (to < from) {
      return new int[0];
    }
    int[] minutes = new int[(int) ((to - from) / step) + 1];
    for (int k = 0; k < minutes.length; k++) {
      minutes[k] = (int) (from + k * step);
    }
    return minutes;
  }
}
