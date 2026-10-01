package io.hron.eval;

import io.hron.ast.ScheduleData;
import io.hron.ast.ScheduleExpr;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.Iterator;
import java.util.List;
import java.util.Optional;

/** A schedule prepared for searching: its zone, cadence, times and clauses resolved once. */
record Search(ScheduleExpr expr, ZoneId zone, Cadence cadence, DailyTimes times, Clauses clauses) {
  static Search of(ScheduleData data, ZoneId zone) {
    LocalDate starting = data.anchor() == null ? null : LocalDate.parse(data.anchor());
    return new Search(
        data.expr(),
        zone,
        Cadence.of(data.expr(), starting),
        DailyTimes.of(data.expr()),
        Clauses.of(data, starting));
  }

  /** The occurrence nearest {@code now} strictly beyond it in {@code direction}. */
  Optional<ZonedDateTime> nearest(ZonedDateTime now, Direction direction) {
    ZonedDateTime local = now.withZoneSameInstant(zone);
    LocalDate firstDate = clauses.clamp(local.toLocalDate(), direction);
    // A nearest weekday or a DST shift can move an occurrence out of the period it is scheduled
    // in, so the search starts one period back.
    long firstPeriod = cadence.periodOf(firstDate) - direction.sign();
    long reach = clauses.farthestExceptDate(direction).map(cadence::periodOf).orElse(firstPeriod);
    Occurrence best = null;
    Iterator<LocalDate> starts = cadence.periodStarts(firstPeriod, reach, direction);
    search:
    while (starts.hasNext()) {
      List<Candidate> candidates = Candidate.candidatesInPeriod(expr, starts.next());
      for (Candidate candidate : direction.inOrder(candidates)) {
        boolean beaten =
            best != null && !Occurrence.couldBeat(candidate.date(), best.date(), direction);
        if (beaten || clauses.endsSearch(candidate.date(), direction)) {
          break search;
        }
        if (!clauses.allows(candidate)) {
          continue;
        }
        Optional<ZonedDateTime> instant = nearestOnDate(candidate.date(), local, direction);
        if (instant.isPresent()
            && (best == null || direction.precedes(instant.get(), best.instant()))) {
          best = new Occurrence(instant.get(), candidate.date());
        }
      }
    }
    return Optional.ofNullable(best).map(Occurrence::instant).filter(Evaluator::inSupportedRange);
  }

  /** The occurrence on {@code date} nearest {@code now} strictly beyond it in {@code direction}. */
  private Optional<ZonedDateTime> nearestOnDate(
      LocalDate date, ZonedDateTime now, Direction direction) {
    return switch (times) {
      case DailyTimes.Fixed(List<LocalTime> fixed) -> nearestFixedTime(fixed, date, now, direction);
      case DailyTimes.Slots(int[] slots) -> nearestSlot(slots, date, now, direction);
    };
  }

  /** A time shifted out of a gap can land after a later wall time, so every time is compared. */
  private Optional<ZonedDateTime> nearestFixedTime(
      List<LocalTime> fixed, LocalDate date, ZonedDateTime now, Direction direction) {
    ZonedDateTime nearest = null;
    for (LocalTime time : fixed) {
      ZonedDateTime instant = WallClock.fixedTimeOn(date, time, zone);
      if (direction.precedes(now, instant)
          && (nearest == null || direction.precedes(instant, nearest))) {
        nearest = instant;
      }
    }
    return Optional.ofNullable(nearest);
  }

  /**
   * Ordered by {@link WallClock#slotOrGapEnd}, a date's slots never go back in time, so a binary
   * search finds where {@code now} falls among them; a scan in {@code direction} then steps past
   * slots a gap skips.
   */
  private Optional<ZonedDateTime> nearestSlot(
      int[] slots, LocalDate date, ZonedDateTime now, Direction direction) {
    Instant target = now.toInstant();
    // low becomes the first slot after now or, going backward, the first not before it.
    int low = 0;
    int high = slots.length;
    while (low < high) {
      int mid = (low + high) >>> 1;
      Instant slot = WallClock.slotOrGapEnd(date, slots[mid], zone);
      boolean atOrBeyondLow =
          direction == Direction.FORWARD ? slot.isAfter(target) : !slot.isBefore(target);
      if (atOrBeyondLow) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    int step = (int) direction.sign();
    for (int i = direction == Direction.FORWARD ? low : low - 1;
        i >= 0 && i < slots.length;
        i += step) {
      Optional<ZonedDateTime> slot = WallClock.slotOn(date, slots[i], zone);
      if (slot.isPresent()) {
        return slot;
      }
    }
    return Optional.empty();
  }
}
