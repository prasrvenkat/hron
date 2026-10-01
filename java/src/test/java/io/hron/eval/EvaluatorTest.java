package io.hron.eval;

import static org.junit.jupiter.api.Assertions.*;

import io.hron.HronException;
import io.hron.Schedule;
import io.hron.ast.DayFilter;
import io.hron.ast.DayOfMonthSpec;
import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.MonthRepeat;
import io.hron.ast.MonthTarget;
import io.hron.ast.ScheduleData;
import io.hron.ast.TimeOfDay;
import io.hron.ast.UntilSpec;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.Test;

/** Schedules only the builder can make, which parse would reject. */
class EvaluatorTest {
  private static final ZoneId UTC = ZoneId.of("UTC");
  private static final ZonedDateTime NOW = ZonedDateTime.parse("2026-02-06T12:00:00Z[UTC]");

  @Test
  void dayNumberNoMonthHasNeverFires() {
    ScheduleData data =
        ScheduleData.of(
            new MonthRepeat(
                1,
                MonthTarget.days(List.of(DayOfMonthSpec.single(65))),
                List.of(new TimeOfDay(9, 0))));
    assertTrue(Evaluator.nextFrom(data, NOW, UTC).isEmpty());
    assertTrue(Evaluator.previousFrom(data, NOW, UTC).isEmpty());
  }

  @Test
  void namedUntilWithoutStartingResolvesFromTheEpoch() throws HronException {
    ScheduleData data =
        Schedule.parse("every day at 09:00").data().withUntil(UntilSpec.named(MonthName.MARCH, 1));
    assertEquals(
        Optional.of(ZonedDateTime.parse("1970-03-01T09:00:00Z[UTC]")),
        Evaluator.previousFrom(data, NOW, UTC));
    assertTrue(Evaluator.nextFrom(data, NOW, UTC).isEmpty());
  }

  @Test
  void zeroDayIntervalRepeatsDaily() {
    ScheduleData data =
        ScheduleData.of(new DayRepeat(0, DayFilter.every(), List.of(new TimeOfDay(9, 0))));
    assertEquals(
        List.of(
            ZonedDateTime.parse("2026-02-07T09:00:00Z[UTC]"),
            ZonedDateTime.parse("2026-02-08T09:00:00Z[UTC]")),
        Evaluator.nextNFrom(data, NOW, 2, UTC));
  }

  @Test
  void zeroMinuteIntervalStepsOneMinute() {
    ScheduleData data =
        ScheduleData.of(
            new IntervalRepeat(
                0, IntervalUnit.MINUTES, new TimeOfDay(9, 0), new TimeOfDay(9, 1), null));
    assertEquals(
        List.of(
            ZonedDateTime.parse("2026-02-07T09:00:00Z[UTC]"),
            ZonedDateTime.parse("2026-02-07T09:01:00Z[UTC]"),
            ZonedDateTime.parse("2026-02-08T09:00:00Z[UTC]")),
        Evaluator.nextNFrom(data, NOW, 3, UTC));
  }
}
