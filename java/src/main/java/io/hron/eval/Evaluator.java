package io.hron.eval;

import io.hron.ast.ScheduleData;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Optional;
import java.util.stream.Stream;

/**
 * Evaluates schedule expressions to compute occurrences (spec/README.md, "Behavioral Semantics").
 */
public final class Evaluator {
  /** spec/README.md, "Supported range": from RANGE_START inclusive to RANGE_END exclusive. */
  static final Instant RANGE_START = Instant.parse("0001-01-02T00:00:00Z");

  static final Instant RANGE_END = Instant.parse("9999-12-30T00:00:00Z");

  private Evaluator() {}

  /**
   * Computes the next occurrence strictly after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param zone the schedule's timezone
   * @return the next occurrence, or empty if none exists or now is outside the supported range
   */
  public static Optional<ZonedDateTime> nextFrom(
      ScheduleData data, ZonedDateTime now, ZoneId zone) {
    return search(data, now, zone, Direction.FORWARD);
  }

  /**
   * Computes the most recent occurrence strictly before the given time.
   *
   * @param data the schedule data
   * @param now the reference time (exclusive upper bound)
   * @param zone the schedule's timezone
   * @return the previous occurrence, or empty if none exists or now is outside the supported range
   */
  public static Optional<ZonedDateTime> previousFrom(
      ScheduleData data, ZonedDateTime now, ZoneId zone) {
    return search(data, now, zone, Direction.BACKWARD);
  }

  /**
   * Computes the next n occurrences strictly after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param n the number of occurrences to compute
   * @param zone the schedule's timezone
   * @return a list of the next n occurrences
   */
  public static List<ZonedDateTime> nextNFrom(
      ScheduleData data, ZonedDateTime now, int n, ZoneId zone) {
    return occurrences(data, now, zone).limit(Math.max(n, 0)).toList();
  }

  /**
   * Returns a lazy stream of occurrences strictly after the given time.
   *
   * @param data the schedule data
   * @param from the reference time (exclusive)
   * @param zone the schedule's timezone
   * @return a stream of occurrences
   */
  public static Stream<ZonedDateTime> occurrences(
      ScheduleData data, ZonedDateTime from, ZoneId zone) {
    if (!inSupportedRange(from)) {
      return Stream.empty();
    }
    Search search = Search.of(data, zone);
    return Stream.iterate(
            search.nearest(from, Direction.FORWARD),
            Optional::isPresent,
            t -> search.nearest(t.get(), Direction.FORWARD))
        .map(Optional::get);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @param data the schedule data
   * @param from the start time (exclusive)
   * @param to the end time (inclusive)
   * @param zone the schedule's timezone
   * @return a stream of occurrences in the range, empty if to is outside the supported range
   */
  public static Stream<ZonedDateTime> between(
      ScheduleData data, ZonedDateTime from, ZonedDateTime to, ZoneId zone) {
    if (!inSupportedRange(to)) {
      return Stream.empty();
    }
    return occurrences(data, from, zone).takeWhile(t -> !t.isAfter(to));
  }

  /**
   * Checks if the minute containing a datetime, on the schedule's wall clock, is an occurrence.
   * Defined through the forward search, so the two can never disagree about what an occurrence is
   * (spec/README.md, "matches is true exactly when the minute containing t is an occurrence").
   *
   * @param data the schedule data
   * @param datetime the datetime to check; its seconds are ignored
   * @param zone the schedule's timezone
   * @return true if the datetime matches
   */
  public static boolean matches(ScheduleData data, ZonedDateTime datetime, ZoneId zone) {
    if (!inSupportedRange(datetime)) {
      return false;
    }
    ZonedDateTime minute = datetime.withZoneSameInstant(zone).truncatedTo(ChronoUnit.MINUTES);
    // An occurrence never lands before the date it is scheduled on, so one at this minute is
    // scheduled on or before the minute's wall date.
    return Search.of(data, zone)
        .endOn(minute.toLocalDate())
        .nearest(minute.minusNanos(1), Direction.FORWARD)
        .filter(minute::isEqual)
        .isPresent();
  }

  static boolean inSupportedRange(ZonedDateTime t) {
    Instant instant = t.toInstant();
    return !instant.isBefore(RANGE_START) && instant.isBefore(RANGE_END);
  }

  private static Optional<ZonedDateTime> search(
      ScheduleData data, ZonedDateTime now, ZoneId zone, Direction direction) {
    if (!inSupportedRange(now)) {
      return Optional.empty();
    }
    return Search.of(data, zone).nearest(now, direction);
  }
}
