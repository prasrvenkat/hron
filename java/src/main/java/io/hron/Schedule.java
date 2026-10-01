package io.hron;

import io.hron.ast.ScheduleData;
import io.hron.cron.CronConverter;
import io.hron.display.Display;
import io.hron.eval.Evaluator;
import io.hron.parser.Parser;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import java.util.Optional;
import java.util.stream.Stream;

public final class Schedule {
  private final ScheduleData data;
  private final ZoneId zoneId;

  private Schedule(ScheduleData data, ZoneId zoneId) {
    this.data = data;
    this.zoneId = zoneId;
  }

  /**
   * Parses an hron expression into a Schedule.
   *
   * @throws HronException if the input is invalid
   */
  public static Schedule parse(String input) throws HronException {
    ScheduleData data = Parser.parse(input);
    ZoneId zoneId = resolveTimezone(data.timezone());
    return new Schedule(data, zoneId);
  }

  /**
   * Converts a 5-field cron expression to the Schedule that fires at the same times on the same
   * dates.
   *
   * @throws HronException of kind {@code CRON} if the cron is invalid or no hron schedule fires as
   *     it does
   */
  public static Schedule fromCron(String cronExpr) throws HronException {
    ScheduleData data = CronConverter.fromCron(cronExpr);
    ZoneId zoneId = resolveTimezone(data.timezone());
    return new Schedule(data, zoneId);
  }

  /** Validates an hron expression without throwing. */
  public static boolean validate(String input) {
    try {
      Parser.parse(input);
      return true;
    } catch (HronException e) {
      return false;
    }
  }

  /**
   * Computes the next occurrence strictly after the given time.
   *
   * @return the next occurrence, or empty if none exists or now is outside the supported range
   */
  public Optional<ZonedDateTime> nextFrom(ZonedDateTime now) {
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.nextFrom(data, nowInTz, zoneId);
  }

  /** Computes the next n occurrences strictly after the given time. */
  public List<ZonedDateTime> nextNFrom(ZonedDateTime now, int n) {
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.nextNFrom(data, nowInTz, n, zoneId);
  }

  /**
   * Computes the most recent occurrence strictly before the given time.
   *
   * @return the previous occurrence, or empty if none exists or now is outside the supported range
   */
  public Optional<ZonedDateTime> previousFrom(ZonedDateTime now) {
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.previousFrom(data, nowInTz, zoneId);
  }

  /** Returns whether the minute containing {@code datetime} is an occurrence. */
  public boolean matches(ZonedDateTime datetime) {
    ZonedDateTime dtInTz = datetime.withZoneSameInstant(zoneId);
    return Evaluator.matches(data, dtInTz, zoneId);
  }

  /**
   * Returns a lazy stream of occurrences strictly after {@code from}, empty if {@code from} is
   * outside the supported range.
   */
  public Stream<ZonedDateTime> occurrences(ZonedDateTime from) {
    ZonedDateTime fromInTz = from.withZoneSameInstant(zoneId);
    return Evaluator.occurrences(data, fromInTz, zoneId);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @return the occurrences in the range, empty if either bound is outside the supported range
   */
  public Stream<ZonedDateTime> between(ZonedDateTime from, ZonedDateTime to) {
    ZonedDateTime fromInTz = from.withZoneSameInstant(zoneId);
    ZonedDateTime toInTz = to.withZoneSameInstant(zoneId);
    return Evaluator.between(data, fromInTz, toInTz, zoneId);
  }

  /**
   * Converts this schedule to a 5-field cron expression that fires at the same times on the same
   * dates. The timezone is not part of the cron: run it in the schedule's timezone.
   *
   * @throws HronException of kind {@code CRON} if no cron expression fires as this schedule does
   */
  public String toCron() throws HronException {
    return CronConverter.toCron(data);
  }

  /**
   * Returns the IANA timezone name with its canonical capitalization, or empty if not specified.
   */
  public Optional<String> timezone() {
    return Optional.ofNullable(data.timezone()).filter(s -> !s.isEmpty());
  }

  /** Returns the canonical string representation of this schedule. */
  @Override
  public String toString() {
    return Display.render(data);
  }

  public ScheduleData data() {
    return data;
  }

  /** UTC when unset, so results never depend on the host zone. */
  private static ZoneId resolveTimezone(String tzName) {
    if (tzName == null || tzName.isEmpty()) {
      return ZoneId.of("UTC");
    }
    return ZoneId.of(tzName);
  }
}
