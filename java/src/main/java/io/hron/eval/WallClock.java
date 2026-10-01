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
 * A wall time a fall-back repeats takes its first pass (spec/README.md, "DST fall-back (ambiguous
 * times)"), as {@link ZonedDateTime#of} resolves it.
 */
final class WallClock {
  static final int MINUTES_PER_HOUR = 60;

  private WallClock() {}

  /**
   * A time in a spring-forward gap shifts forward by the gap's length (spec/README.md, "DST
   * spring-forward (gaps)"), as {@link ZonedDateTime#of} shifts it.
   */
  static ZonedDateTime fixedTimeOn(LocalDate date, LocalTime time, ZoneId zone) {
    return ZonedDateTime.of(date.atTime(time), zone);
  }

  /**
   * An interval slot on a date: where it sits in time, and its instant unless a spring-forward gap
   * skips it (spec/README.md, "Interval slots in a spring-forward gap"). A skipped slot sits at the
   * instant its gap ends, so keys never decrease in wall-clock order and one binary search finds
   * the slots on either side of an instant.
   */
  record Slot(Instant key, Optional<ZonedDateTime> instant) {}

  static Slot slotOn(LocalDate date, int minute, ZoneId zone) {
    LocalDateTime wallTime = wallTime(date, minute);
    ZoneRules rules = zone.getRules();
    List<ZoneOffset> offsets = rules.getValidOffsets(wallTime);
    if (offsets.isEmpty()) {
      return new Slot(rules.getTransition(wallTime).getInstant(), Optional.empty());
    }
    ZonedDateTime instant = ZonedDateTime.ofLocal(wallTime, zone, offsets.getFirst());
    return new Slot(instant.toInstant(), Optional.of(instant));
  }

  private static LocalDateTime wallTime(LocalDate date, int minute) {
    return date.atTime(minute / MINUTES_PER_HOUR, minute % MINUTES_PER_HOUR);
  }
}
