package io.hron.eval;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.time.zone.ZoneRules;
import java.util.List;
import java.util.Optional;

/**
 * Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its first pass
 * (spec/README.md, "DST fall-back (ambiguous times)"), as {@link ZonedDateTime#of} resolves it.
 */
final class WallClock {
  static final int MINUTES_PER_HOUR = 60;

  private WallClock() {}

  /**
   * The instant {@code time} names on {@code date}, shifted forward by the gap's length when it
   * falls in a spring-forward gap (spec/README.md, "DST spring-forward (gaps)"), as {@link
   * ZonedDateTime#of} shifts it.
   */
  static ZonedDateTime fixedTimeOn(LocalDate date, LocalTime time, ZoneId zone) {
    return ZonedDateTime.of(date.atTime(time), zone);
  }

  /**
   * The instant of the interval slot {@code minute} minutes after midnight on {@code date}, or
   * empty when that wall time falls in a spring-forward gap (spec/README.md, "Interval slots in a
   * spring-forward gap").
   */
  static Optional<ZonedDateTime> slotOn(LocalDate date, int minute, ZoneId zone) {
    LocalDateTime wallTime = wallTime(date, minute);
    if (zone.getRules().getValidOffsets(wallTime).isEmpty()) {
      return Optional.empty();
    }
    return Optional.of(ZonedDateTime.of(wallTime, zone));
  }

  /**
   * The instant of the slot {@code minute} minutes after midnight on {@code date}, or of the end of
   * the gap it falls in: unlike {@link #slotOn}, defined for every minute, and never decreasing as
   * the minute advances.
   */
  static Instant slotOrGapEnd(LocalDate date, int minute, ZoneId zone) {
    LocalDateTime wallTime = wallTime(date, minute);
    ZoneRules rules = zone.getRules();
    List<ZoneOffset> offsets = rules.getValidOffsets(wallTime);
    return offsets.isEmpty()
        ? rules.getTransition(wallTime).getInstant()
        : wallTime.toInstant(offsets.getFirst());
  }

  private static LocalDateTime wallTime(LocalDate date, int minute) {
    return date.atTime(minute / MINUTES_PER_HOUR, minute % MINUTES_PER_HOUR);
  }
}
