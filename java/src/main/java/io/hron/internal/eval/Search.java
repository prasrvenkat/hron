package io.hron.internal.eval;

import io.hron.ast.ScheduleData;
import io.hron.ast.ScheduleExpr;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.util.List;
import java.util.Optional;

record Search(ScheduleExpr expr, ZoneId zone, Cadence cadence, DailyTimes times, Clauses clauses) {
  static Search of(ScheduleData data) {
    LocalDate starting = data.anchor() == null ? null : LocalDate.parse(data.anchor());
    return new Search(
        data.expr(),
        data.timezone() == null ? ZoneId.of("UTC") : ZoneId.of(data.timezone()),
        Cadence.of(data.expr(), starting),
        DailyTimes.of(data.expr()),
        Clauses.of(data, starting));
  }

  Search endOn(LocalDate date) {
    return new Search(expr, zone, cadence, times, clauses.endOn(date));
  }

  Optional<ZonedDateTime> nearest(ZonedDateTime now, Direction direction) {
    ZonedDateTime local = now.withZoneSameInstant(zone);
    LocalDate nowDate = local.toLocalDate();
    LocalDate firstDate = clauses.clamp(nowDate, direction);
    // A nearest weekday or a DST shift can move an occurrence out of the period it is scheduled
    // in, so the search starts one period back.
    long firstPeriod = cadence.periodOf(firstDate) - direction.sign();
    long reach = clauses.farthestExceptDate(direction).map(cadence::periodOf).orElse(firstPeriod);
    long shift = times.maxShiftDays();
    Occurrence best = null;
    search:
    for (LocalDate start : cadence.periodStarts(firstPeriod, reach, direction)) {
      if (rejectsPeriod(start)) {
        continue;
      }
      List<Candidate> candidates = Candidate.candidatesInPeriod(expr, start);
      for (Candidate candidate : direction.inOrder(candidates)) {
        boolean beaten =
            best != null
                && !Occurrence.couldBeat(candidate.date(), best.landing(), direction, shift);
        if (beaten || clauses.endsSearch(candidate.date(), direction)) {
          break search;
        }
        if (Occurrence.isBehind(candidate.date(), nowDate, direction, shift)
            || !clauses.allows(candidate)) {
          continue;
        }
        Optional<ZonedDateTime> instant = nearestOnDate(candidate.date(), local, direction);
        if (instant.isPresent()
            && (best == null || direction.precedes(instant.get(), best.instant()))) {
          best = new Occurrence(instant.get(), instant.get().toLocalDate());
        }
      }
    }
    return Optional.ofNullable(best).map(Occurrence::instant).filter(Evaluator::inSupportedRange);
  }

  /**
   * A day or month period's candidates all target its own month, so one whose month {@code during}
   * rejects holds nothing.
   */
  private boolean rejectsPeriod(LocalDate start) {
    return (cadence.unit() == Cadence.Unit.DAY || cadence.unit() == Cadence.Unit.MONTH)
        && !clauses.allowsMonth(start.getMonth());
  }

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
   * A date's slot keys never decrease in wall-clock order ({@link WallClock.Slot}), so one binary
   * search finds where {@code now} falls among them; a scan in {@code direction} then steps past
   * slots a gap skips.
   */
  private Optional<ZonedDateTime> nearestSlot(
      int[] slots, LocalDate date, ZonedDateTime now, Direction direction) {
    Instant target = now.toInstant();
    // low becomes the first slot of the upper part: forward, the slots after now; backward, the
    // slots at or after it.
    int low = 0;
    int high = slots.length;
    while (low < high) {
      int mid = (low + high) >>> 1;
      Instant key = WallClock.slotOn(date, slots[mid], zone).key();
      boolean inUpperPart =
          direction == Direction.FORWARD ? key.isAfter(target) : !key.isBefore(target);
      if (inUpperPart) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    int step = (int) direction.sign();
    for (int i = direction == Direction.FORWARD ? low : low - 1;
        i >= 0 && i < slots.length;
        i += step) {
      Optional<ZonedDateTime> instant = WallClock.slotOn(date, slots[i], zone).instant();
      if (instant.isPresent()) {
        return instant;
      }
    }
    return Optional.empty();
  }
}
