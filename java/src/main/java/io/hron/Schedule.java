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

/**
 * The main entry point for parsing and evaluating hron schedule expressions.
 *
 * <p>Example usage:
 *
 * <pre>{@code
 * Schedule schedule = Schedule.parse("every weekday at 9:00 except dec 25 in America/New_York");
 * Optional<ZonedDateTime> next = schedule.nextFrom(ZonedDateTime.now());
 * if (next.isPresent()) {
 *     System.out.println("Next occurrence: " + next.get());
 * }
 * }</pre>
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
   * @param input the hron expression
   * @return the parsed schedule
   * @throws HronException if the input is invalid
   */
  public static Schedule parse(String input) throws HronException {
    ScheduleData data = Parser.parse(input);
    ZoneId zoneId = resolveTimezone(data.timezone());
    return new Schedule(data, zoneId);
  }

  /**
   * Converts a 5-field cron expression to a Schedule.
   *
   * @param cronExpr the cron expression
   * @return the parsed schedule
   * @throws HronException if the cron expression is invalid
   */
  public static Schedule fromCron(String cronExpr) throws HronException {
    ScheduleData data = CronConverter.fromCron(cronExpr);
    ZoneId zoneId = resolveTimezone(data.timezone());
    return new Schedule(data, zoneId);
  }

  /**
   * Validates an hron expression without throwing.
   *
   * @param input the hron expression
   * @return true if the expression is valid
   */
  public static boolean validate(String input) {
    try {
      Parser.parse(input);
      return true;
    } catch (HronException e) {
      return false;
    }
  }

  /**
   * Computes the next occurrence after the given time.
   *
   * @param now the reference time
   * @return the next occurrence, or empty if none exists
   */
  public Optional<ZonedDateTime> nextFrom(ZonedDateTime now) {
    // Convert now to the schedule's timezone
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.nextFrom(data, nowInTz, zoneId);
  }

  /**
   * Computes the next n occurrences after the given time.
   *
   * @param now the reference time
   * @param n the number of occurrences to compute
   * @return a list of the next n occurrences
   */
  public List<ZonedDateTime> nextNFrom(ZonedDateTime now, int n) {
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.nextNFrom(data, nowInTz, n, zoneId);
  }

  /**
   * Computes the most recent occurrence strictly before the given time.
   *
   * @param now the reference time (exclusive upper bound)
   * @return the previous occurrence, or empty if none exists
   */
  public Optional<ZonedDateTime> previousFrom(ZonedDateTime now) {
    ZonedDateTime nowInTz = now.withZoneSameInstant(zoneId);
    return Evaluator.previousFrom(data, nowInTz, zoneId);
  }

  /**
   * Checks if a datetime matches this schedule.
   *
   * @param datetime the datetime to check
   * @return true if the datetime matches
   */
  public boolean matches(ZonedDateTime datetime) {
    ZonedDateTime dtInTz = datetime.withZoneSameInstant(zoneId);
    return Evaluator.matches(data, dtInTz, zoneId);
  }

  /**
   * Returns a lazy stream of occurrences starting after the given time.
   *
   * @param from the reference time (exclusive)
   * @return a stream of occurrences
   */
  public Stream<ZonedDateTime> occurrences(ZonedDateTime from) {
    ZonedDateTime fromInTz = from.withZoneSameInstant(zoneId);
    return Evaluator.occurrences(data, fromInTz, zoneId);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @param from the start time (exclusive)
   * @param to the end time (inclusive)
   * @return a stream of occurrences in the range
   */
  public Stream<ZonedDateTime> between(ZonedDateTime from, ZonedDateTime to) {
    ZonedDateTime fromInTz = from.withZoneSameInstant(zoneId);
    ZonedDateTime toInTz = to.withZoneSameInstant(zoneId);
    return Evaluator.between(data, fromInTz, toInTz, zoneId);
  }

  /**
   * Converts this schedule to a 5-field cron expression.
   *
   * @return the cron expression
   * @throws HronException if the schedule cannot be expressed as cron
   */
  public String toCron() throws HronException {
    return CronConverter.toCron(data);
  }

  /**
   * Returns the IANA timezone name, or empty if not specified.
   *
   * @return the timezone name
   */
  public Optional<String> timezone() {
    return Optional.ofNullable(data.timezone()).filter(s -> !s.isEmpty());
  }

  /**
   * Returns the canonical string representation of this schedule.
   *
   * @return the canonical form
   */
  @Override
  public String toString() {
    return Display.render(data);
  }

  /**
   * Returns the underlying schedule data.
   *
   * @return the schedule data
   */
  public ScheduleData data() {
    return data;
  }

  /** Resolve timezone, defaulting to UTC for deterministic behavior. */
  private static ZoneId resolveTimezone(String tzName) {
    if (tzName == null || tzName.isEmpty()) {
      return ZoneId.of("UTC");
    }
    return ZoneId.of(tzName);
  }
}
