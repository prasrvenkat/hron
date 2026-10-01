package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import java.time.LocalDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.Executable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.MethodSource;

class TimestampsTest {
  private static final ZoneId UTC = ZoneId.of("UTC");
  private static final ZonedDateTime NOW = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, UTC);

  static Stream<Arguments> platformLimits() {
    List<String> expressions =
        List.of(
            "every day at 09:00",
            "every day at 09:00 in America/New_York",
            "every day at 09:00 in Pacific/Kiritimati");
    List<ZoneId> zones =
        List.of(
            UTC, ZoneOffset.of("+18:00"), ZoneOffset.of("-18:00"), ZoneId.of("Pacific/Kiritimati"));
    List<Arguments> cases = new ArrayList<>();
    for (String expression : expressions) {
      for (ZoneId zone : zones) {
        cases.add(Arguments.of(expression, LocalDateTime.MIN.atZone(zone)));
        cases.add(Arguments.of(expression, LocalDateTime.MAX.atZone(zone)));
      }
    }
    return cases.stream();
  }

  @ParameterizedTest(name = "{0} at {1}")
  @MethodSource("platformLimits")
  void platformLimitsAreOutsideTheSupportedRange(String expression, ZonedDateTime t)
      throws HronException {
    Schedule s = Schedule.parse(expression);
    assertAll(
        () -> assertEquals(Optional.empty(), s.nextFrom(t), "nextFrom"),
        () -> assertEquals(Optional.empty(), s.previousFrom(t), "previousFrom"),
        () -> assertEquals(List.of(), s.nextNFrom(t, 3), "nextNFrom"),
        () -> assertFalse(s.matches(t), "matches"),
        () -> assertEquals(List.of(), s.occurrences(t).toList(), "occurrences"),
        () -> assertEquals(List.of(), s.between(t, NOW).toList(), "between(t, now)"),
        () -> assertEquals(List.of(), s.between(NOW, t).toList(), "between(now, t)"));
  }

  @Test
  void nullTimestampsThrowNullPointerException() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    ZonedDateTime outOfRange = LocalDateTime.MAX.atZone(UTC);
    List<Executable> calls =
        List.of(
            () -> s.nextFrom(null),
            () -> s.previousFrom(null),
            () -> s.nextNFrom(null, 3),
            () -> s.nextNFrom(null, 0),
            () -> s.matches(null),
            () -> s.occurrences(null),
            () -> s.between(null, NOW),
            () -> s.between(NOW, null),
            () -> s.between(null, outOfRange),
            () -> s.between(outOfRange, null));
    for (int i = 0; i < calls.size(); i++) {
      Throwable thrown = assertThrows(Throwable.class, calls.get(i), "call " + i);
      assertEquals(NullPointerException.class, thrown.getClass(), "call " + i);
    }
  }

  @ParameterizedTest(name = "{0}")
  @CsvSource({
    "every day at 09:00, UTC",
    "every day at 09:00 in America/New_York, America/New_York",
    "every day at 09:00 in us/eastern, US/Eastern",
    "every day at 09:00 in Etc/GMT-14, Etc/GMT-14"
  })
  void resultsAreInTheScheduleZoneWhateverZoneTheArgumentIsIn(String expression, String zoneName)
      throws HronException {
    Schedule s = Schedule.parse(expression);
    ZoneId zone = ZoneId.of(zoneName);
    for (ZoneId argumentZone :
        List.of(UTC, ZoneOffset.UTC, ZoneOffset.ofHours(9), ZoneId.of("Asia/Tokyo"))) {
      ZonedDateTime now = NOW.withZoneSameInstant(argumentZone);
      List<ZonedDateTime> results = new ArrayList<>();
      results.add(s.nextFrom(now).orElseThrow());
      results.add(s.previousFrom(now).orElseThrow());
      results.addAll(s.nextNFrom(now, 3));
      results.addAll(s.occurrences(now).limit(3).toList());
      results.addAll(s.between(now, now.plusDays(3)).toList());
      assertEquals(11, results.size(), "from " + now);
      for (ZonedDateTime result : results) {
        assertEquals(zone, result.getZone(), "from " + now + ": " + result);
      }
    }
  }

  @Test
  void nextNFromReturnsNothingWhenNIsZeroOrNegative() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertEquals(List.of(), s.nextNFrom(NOW, 0));
    assertEquals(List.of(), s.nextNFrom(NOW, -1));
    assertEquals(List.of(), s.nextNFrom(NOW, Integer.MIN_VALUE));
  }

  @Test
  void nextNFromOnlyCapsTheCount() throws HronException {
    Schedule s = Schedule.parse("on 2026-03-01 at 09:00");
    assertEquals(
        List.of(ZonedDateTime.of(2026, 3, 1, 9, 0, 0, 0, UTC)),
        s.nextNFrom(NOW, Integer.MAX_VALUE));
  }
}
