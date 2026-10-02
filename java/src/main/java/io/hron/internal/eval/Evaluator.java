package io.hron.internal.eval;

import io.hron.Schedule;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.IntervalUnit;
import java.time.Instant;
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

  public static Optional<ZonedDateTime> nextFrom(Schedule schedule, ZonedDateTime now) {
    return search(schedule, now, Direction.FORWARD);
  }

  public static Optional<ZonedDateTime> previousFrom(Schedule schedule, ZonedDateTime now) {
    return search(schedule, now, Direction.BACKWARD);
  }

  public static List<ZonedDateTime> nextNFrom(Schedule schedule, ZonedDateTime now, int n) {
    return occurrences(schedule, now).limit(Math.max(n, 0)).toList();
  }

  public static Stream<ZonedDateTime> occurrences(Schedule schedule, ZonedDateTime from) {
    if (!inSupportedRange(from)) {
      return Stream.empty();
    }
    Search search = Search.of(schedule);
    return Stream.iterate(
            search.nearest(from, Direction.FORWARD),
            Optional::isPresent,
            t -> search.nearest(t.get(), Direction.FORWARD))
        .map(Optional::get);
  }

  public static Stream<ZonedDateTime> between(
      Schedule schedule, ZonedDateTime from, ZonedDateTime to) {
    if (!inSupportedRange(to)) {
      return Stream.empty();
    }
    return occurrences(schedule, from).takeWhile(t -> !t.isAfter(to));
  }

  /**
   * Defined through the forward search, so the two can never disagree about what an occurrence is
   * (spec/README.md, "matches is true exactly when the minute containing t is an occurrence").
   */
  public static boolean matches(Schedule schedule, ZonedDateTime datetime) {
    if (!inSupportedRange(datetime)) {
      return false;
    }
    Search search = Search.of(schedule);
    ZonedDateTime minute =
        datetime.withZoneSameInstant(search.zone()).truncatedTo(ChronoUnit.MINUTES);
    // An occurrence never lands before the date it is scheduled on, so one at this minute is
    // scheduled on or before the minute's wall date.
    return search
        .endOn(minute.toLocalDate())
        .nearest(minute.minusNanos(1), Direction.FORWARD)
        .filter(minute::isEqual)
        .isPresent();
  }

  /**
   * toCron shares the slots so that it writes those evaluation steps through. It takes the
   * Schedule, not its IntervalRepeat, as only a Schedule's parts are checked.
   */
  public static int[] intervalSlots(Schedule schedule) {
    if (!(schedule.expression() instanceof IntervalRepeat ir)) {
      throw new IllegalArgumentException("not an interval repeat: " + schedule);
    }
    return intervalSlots(ir);
  }

  /** The step is a long, as 2147483647 hours in minutes overflows an int. */
  static int[] intervalSlots(IntervalRepeat ir) {
    long minutesPerUnit = ir.unit() == IntervalUnit.HOURS ? WallClock.MINUTES_PER_HOUR : 1;
    long step = ir.interval() * minutesPerUnit;
    int from = ir.fromTime().totalMinutes();
    int to = ir.toTime().totalMinutes();
    int[] minutes = new int[(int) ((to - from) / step) + 1];
    for (int k = 0; k < minutes.length; k++) {
      minutes[k] = (int) (from + k * step);
    }
    return minutes;
  }

  static boolean inSupportedRange(ZonedDateTime t) {
    Instant instant = t.toInstant();
    return !instant.isBefore(RANGE_START) && instant.isBefore(RANGE_END);
  }

  private static Optional<ZonedDateTime> search(
      Schedule schedule, ZonedDateTime now, Direction direction) {
    if (!inSupportedRange(now)) {
      return Optional.empty();
    }
    return Search.of(schedule).nearest(now, direction);
  }
}
