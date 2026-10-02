package io.hron;

import io.hron.ast.ExceptionSpec;
import io.hron.ast.MonthName;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.UntilSpec;
import io.hron.internal.ScheduleData;
import io.hron.internal.cron.CronConverter;
import io.hron.internal.display.Display;
import io.hron.internal.eval.Evaluator;
import io.hron.internal.parser.Parser;
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

  private Schedule(ScheduleData data) {
    this.data = data;
  }

  /**
   * Parses an hron expression into a Schedule.
   *
   * @throws HronException if the input is invalid
   * @throws NullPointerException if input is null
   */
  public static Schedule parse(String input) throws HronException {
    return new Schedule(Parser.parse(Objects.requireNonNull(input, "input")));
  }

  /**
   * Converts a 5-field cron expression to the Schedule that fires at the same times on the same
   * dates.
   *
   * @throws HronException of kind {@code CRON} if the cron is invalid or no hron schedule fires as
   *     it does
   * @throws NullPointerException if cronExpr is null
   */
  public static Schedule fromCron(String cronExpr) throws HronException {
    return new Schedule(CronConverter.fromCron(Objects.requireNonNull(cronExpr, "cronExpr")));
  }

  /**
   * Returns whether {@link #parse} accepts the input.
   *
   * @throws NullPointerException if input is null
   */
  public static boolean validate(String input) {
    Objects.requireNonNull(input, "input");
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
    return Evaluator.nextFrom(this, Objects.requireNonNull(now, "now"));
  }

  /**
   * Computes the next occurrences strictly after {@code now}.
   *
   * @return at most n occurrences, none when n &lt;= 0 or now is outside the supported range
   * @throws NullPointerException if now is null
   */
  public List<ZonedDateTime> nextNFrom(ZonedDateTime now, int n) {
    return Evaluator.nextNFrom(this, Objects.requireNonNull(now, "now"), n);
  }

  /**
   * Computes the most recent occurrence strictly before {@code now}.
   *
   * @return the previous occurrence, or empty if none exists or now is outside the supported range
   * @throws NullPointerException if now is null
   */
  public Optional<ZonedDateTime> previousFrom(ZonedDateTime now) {
    return Evaluator.previousFrom(this, Objects.requireNonNull(now, "now"));
  }

  /**
   * Returns whether the minute containing {@code datetime} is an occurrence; false if datetime is
   * outside the supported range.
   *
   * @throws NullPointerException if datetime is null
   */
  public boolean matches(ZonedDateTime datetime) {
    return Evaluator.matches(this, Objects.requireNonNull(datetime, "datetime"));
  }

  /**
   * Returns a lazy stream of occurrences strictly after {@code from}, empty if {@code from} is
   * outside the supported range.
   *
   * @throws NullPointerException if from is null
   */
  public Stream<ZonedDateTime> occurrences(ZonedDateTime from) {
    return Evaluator.occurrences(this, Objects.requireNonNull(from, "from"));
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
    return Evaluator.between(this, from, to);
  }

  /**
   * Converts this schedule to a 5-field cron expression that fires at the same times on the same
   * dates. The timezone is not part of the cron: run it in the schedule's timezone.
   *
   * @throws HronException of kind {@code CRON} if no cron expression fires as this schedule does
   */
  public String toCron() throws HronException {
    return CronConverter.toCron(this);
  }

  /**
   * Returns the IANA timezone name with its canonical capitalization, or empty if not specified.
   */
  public Optional<String> timezone() {
    return Optional.ofNullable(data.timezone()).filter(s -> !s.isEmpty());
  }

  public ScheduleExpr expression() {
    return data.expression();
  }

  /** Returns the except dates, an unmodifiable list, empty without an except clause. */
  public List<ExceptionSpec> except() {
    return data.except();
  }

  /** Returns the until date, or empty if not specified. */
  public Optional<UntilSpec> until() {
    return Optional.ofNullable(data.until());
  }

  /** Returns the starting date as YYYY-MM-DD, or empty if not specified. */
  public Optional<String> starting() {
    return Optional.ofNullable(data.starting());
  }

  /** Returns the during months, an unmodifiable list, empty without a during clause. */
  public List<MonthName> during() {
    return data.during();
  }

  /** Returns the canonical string representation of this schedule. */
  @Override
  public String toString() {
    return Display.render(this);
  }

  /**
   * Returns whether other is a schedule with equal parts, comparing lists in order (spec/README.md,
   * "Equality").
   */
  @Override
  public boolean equals(Object other) {
    return other instanceof Schedule schedule && data.equals(schedule.data);
  }

  @Override
  public int hashCode() {
    return data.hashCode();
  }
}
