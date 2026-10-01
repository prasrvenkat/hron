package io.hron.eval;

import static org.junit.jupiter.api.Assertions.*;

import io.hron.ast.DayOfMonthSpec;
import io.hron.ast.MonthRepeat;
import io.hron.ast.MonthTarget;
import io.hron.ast.ScheduleData;
import io.hron.ast.TimeOfDay;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
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
}
