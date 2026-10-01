package io.hron;

import io.hron.ast.ScheduleData;
import io.hron.cron.CronConverter;
import io.hron.display.Display;
import io.hron.eval.Evaluator;
import io.hron.parser.Parser;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.stream.Stream;

/**
 * A parsed hron schedule. Only the instant of a timestamp argument matters, not its zone; every
 * returned timestamp is in the schedule's timezone, or {@code ZoneId.of("UTC")} when it has none.
 */
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
   * Computes the next occurrence strictly after {@code now}.
   *
   * @return the next occurrence, or empty if none exists or now is outside the supported range
   * @throws NullPointerException if now is null
   */
  public Optional<ZonedDateTime> nextFrom(ZonedDateTime now) {
    return Evaluator.nextFrom(data, Objects.requireNonNull(now, "now"), zoneId);
  }

  /**
   * Computes the next occurrences strictly after {@code now}.
   *
   * @return at most n occurrences, none when n &lt;= 0 or now is outside the supported range
   * @throws NullPointerException if now is null
   */
  public List<ZonedDateTime> nextNFrom(ZonedDateTime now, int n) {
    return Evaluator.nextNFrom(data, Objects.requireNonNull(now, "now"), n, zoneId);
  }

  /**
   * Computes the most recent occurrence strictly before {@code now}.
   *
   * @return the previous occurrence, or empty if none exists or now is outside the supported range
   * @throws NullPointerException if now is null
   */
  public Optional<ZonedDateTime> previousFrom(ZonedDateTime now) {
    return Evaluator.previousFrom(data, Objects.requireNonNull(now, "now"), zoneId);
  }

  /**
   * Returns whether the minute containing {@code datetime} is an occurrence; false if datetime is
   * outside the supported range.
   *
   * @throws NullPointerException if datetime is null
   */
  public boolean matches(ZonedDateTime datetime) {
    return Evaluator.matches(data, Objects.requireNonNull(datetime, "datetime"), zoneId);
  }

  /**
   * Returns a lazy stream of occurrences strictly after {@code from}, empty if {@code from} is
   * outside the supported range.
   *
   * @throws NullPointerException if from is null
   */
  public Stream<ZonedDateTime> occurrences(ZonedDateTime from) {
    return Evaluator.occurrences(data, Objects.requireNonNull(from, "from"), zoneId);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @return the occurrences in the range, empty if either bound is outside the supported range
   * @throws NullPointerException if from or to is null
   */
  public Stream<ZonedDateTime> between(ZonedDateTime from, ZonedDateTime to) {
    Objects.requireNonNull(from, "from");
    Objects.requireNonNull(to, "to");
    return Evaluator.between(data, from, to, zoneId);
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
