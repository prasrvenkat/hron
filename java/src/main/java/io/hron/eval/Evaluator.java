package io.hron.eval;

import io.hron.ast.ScheduleData;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.temporal.ChronoUnit;
import java.util.List;
import java.util.Optional;
import java.util.stream.Stream;

public final class Evaluator {
  /** spec/README.md, "Supported range": from RANGE_START inclusive to RANGE_END exclusive. */
  static final Instant RANGE_START = Instant.parse("0001-01-02T00:00:00Z");

  static final Instant RANGE_END = Instant.parse("9999-12-30T00:00:00Z");

  private Evaluator() {}

  public static Optional<ZonedDateTime> nextFrom(
      ScheduleData data, ZonedDateTime now, ZoneId zone) {
    return search(data, now, zone, Direction.FORWARD);
  }

  public static Optional<ZonedDateTime> previousFrom(
      ScheduleData data, ZonedDateTime now, ZoneId zone) {
    return search(data, now, zone, Direction.BACKWARD);
  }

  public static List<ZonedDateTime> nextNFrom(
      ScheduleData data, ZonedDateTime now, int n, ZoneId zone) {
    return occurrences(data, now, zone).limit(Math.max(n, 0)).toList();
  }

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

  public static Stream<ZonedDateTime> between(
      ScheduleData data, ZonedDateTime from, ZonedDateTime to, ZoneId zone) {
    if (!inSupportedRange(to)) {
      return Stream.empty();
    }
    return occurrences(data, from, zone).takeWhile(t -> !t.isAfter(to));
  }

  /**
   * Defined through the forward search, so the two can never disagree about what an occurrence is
   * (spec/README.md, "matches is true exactly when the minute containing t is an occurrence").
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
