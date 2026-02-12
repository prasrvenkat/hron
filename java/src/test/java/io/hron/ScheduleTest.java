package io.hron;

import static org.junit.jupiter.api.Assertions.*;

import java.time.ZoneId;
import java.time.ZonedDateTime;
import org.junit.jupiter.api.Test;

/** Additional unit tests for Schedule functionality. */
public class ScheduleTest {

  @Test
  void testParseSimple() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertEquals("every day at 09:00", s.toString());
  }

  @Test
  void testParseWeekday() throws HronException {
    Schedule s = Schedule.parse("every weekday at 9:00");
    assertEquals("every weekday at 09:00", s.toString());
  }

  @Test
  void testParseWeekend() throws HronException {
    Schedule s = Schedule.parse("every weekend at 10:00");
    assertEquals("every weekend at 10:00", s.toString());
  }

  @Test
  void testParseSpecificDays() throws HronException {
    Schedule s = Schedule.parse("every mon, wed, fri at 9:00");
    assertEquals("every monday, wednesday, friday at 09:00", s.toString());
  }

  @Test
  void testParseInterval() throws HronException {
    Schedule s = Schedule.parse("every 30 min from 09:00 to 17:00");
    assertEquals("every 30 min from 09:00 to 17:00", s.toString());
  }

  @Test
  void testParseWeekRepeat() throws HronException {
    Schedule s = Schedule.parse("every 2 weeks on monday at 9:00");
    assertEquals("every 2 weeks on monday at 09:00", s.toString());
  }

  @Test
  void testParseMonthRepeat() throws HronException {
    Schedule s = Schedule.parse("every month on the 1st at 9:00");
    assertEquals("every month on the 1st at 09:00", s.toString());
  }

  @Test
  void testParseMonthRepeatLastDay() throws HronException {
    Schedule s = Schedule.parse("every month on the last day at 17:00");
    assertEquals("every month on the last day at 17:00", s.toString());
  }

  @Test
  void testParseOrdinalRepeat() throws HronException {
    Schedule s = Schedule.parse("first monday of every month at 10:00");
    assertEquals("first monday of every month at 10:00", s.toString());
  }

  @Test
  void testParseSingleDate() throws HronException {
    Schedule s = Schedule.parse("on feb 14 at 9:00");
    assertEquals("on feb 14 at 09:00", s.toString());
  }

  @Test
  void testParseYearRepeat() throws HronException {
    Schedule s = Schedule.parse("every year on dec 25 at 00:00");
    assertEquals("every year on dec 25 at 00:00", s.toString());
  }

  @Test
  void testParseWithExcept() throws HronException {
    Schedule s = Schedule.parse("every weekday at 9:00 except dec 25");
    assertEquals("every weekday at 09:00 except dec 25", s.toString());
  }

  @Test
  void testParseWithUntil() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 until 2026-12-31");
    assertEquals("every day at 09:00 until 2026-12-31", s.toString());
  }

  @Test
  void testParseWithStarting() throws HronException {
    Schedule s = Schedule.parse("every 2 weeks on monday at 9:00 starting 2026-01-05");
    assertEquals("every 2 weeks on monday at 09:00 starting 2026-01-05", s.toString());
  }

  @Test
  void testParseWithDuring() throws HronException {
    Schedule s = Schedule.parse("every day at 9:00 during jan, jun");
    assertEquals("every day at 09:00 during jan, jun", s.toString());
  }

  @Test
  void testParseWithTimezone() throws HronException {
    Schedule s = Schedule.parse("every weekday at 9:00 in America/New_York");
    assertEquals("every weekday at 09:00 in America/New_York", s.toString());
    assertTrue(s.timezone().isPresent());
    assertEquals("America/New_York", s.timezone().get());
  }

  @Test
  void testParseWithAllClauses() throws HronException {
    Schedule s =
        Schedule.parse(
            "every weekday at 9:00 except dec 25 until 2027-12-31 starting 2026-01-01 during jan,"
                + " dec in UTC");
    assertEquals(
        "every weekday at 09:00 except dec 25 until 2027-12-31 starting 2026-01-01 during jan, dec"
            + " in UTC",
        s.toString());
  }

  @Test
  void testCaseInsensitivity() throws HronException {
    Schedule s = Schedule.parse("Every Weekday At 9:00");
    assertEquals("every weekday at 09:00", s.toString());
  }

  @Test
  void testValidateReturnsTrue() {
    assertTrue(Schedule.validate("every day at 09:00"));
    assertTrue(Schedule.validate("every weekday at 9:00 in America/New_York"));
  }

  @Test
  void testValidateReturnsFalse() {
    assertFalse(Schedule.validate(""));
    assertFalse(Schedule.validate("hello world"));
    assertFalse(Schedule.validate("every"));
  }

  @Test
  void testNextFromBasic() throws HronException {
    Schedule s = Schedule.parse("every day at 15:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var next = s.nextFrom(now);

    assertTrue(next.isPresent());
    assertEquals(2026, next.get().getYear());
    assertEquals(2, next.get().getMonthValue());
    assertEquals(6, next.get().getDayOfMonth());
    assertEquals(15, next.get().getHour());
    assertEquals(0, next.get().getMinute());
  }

  @Test
  void testNextNFromBasic() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00 in UTC");
    ZonedDateTime now = ZonedDateTime.of(2026, 2, 6, 12, 0, 0, 0, ZoneId.of("UTC"));
    var results = s.nextNFrom(now, 5);

    assertEquals(5, results.size());
    // First should be Feb 7 (today's 09:00 has passed)
    assertEquals(7, results.get(0).getDayOfMonth());
    assertEquals(8, results.get(1).getDayOfMonth());
    assertEquals(9, results.get(2).getDayOfMonth());
  }

  @Test
  void testToCronBasic() throws HronException {
    Schedule s = Schedule.parse("every day at 09:00");
    assertEquals("0 9 * * *", s.toCron());
  }

  @Test
  void testToCronWeekday() throws HronException {
    Schedule s = Schedule.parse("every weekday at 09:00");
    assertEquals("0 9 * * 1-5", s.toCron());
  }

  @Test
  void testToCronWeekend() throws HronException {
    Schedule s = Schedule.parse("every weekend at 10:00");
    assertEquals("0 10 * * 0,6", s.toCron());
  }

  @Test
  void testToCronInterval() throws HronException {
    Schedule s = Schedule.parse("every 30 min from 00:00 to 23:59");
    assertEquals("*/30 * * * *", s.toCron());
  }

  @Test
  void testFromCronBasic() throws HronException {
    Schedule s = Schedule.fromCron("0 9 * * *");
    assertEquals("every day at 09:00", s.toString());
  }

  @Test
  void testFromCronWeekday() throws HronException {
    Schedule s = Schedule.fromCron("0 9 * * 1-5");
    assertEquals("every weekday at 09:00", s.toString());
  }

  @Test
  void testParseError() {
    HronException e = assertThrows(HronException.class, () -> Schedule.parse("not a schedule"));
    // "not" is not a recognized keyword, so it fails at the lexer stage
    assertEquals(ErrorKind.LEX, e.kind());
  }
}
