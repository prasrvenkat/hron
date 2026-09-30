package io.hron.eval;

import io.hron.ast.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.time.zone.ZoneRules;
import java.util.Comparator;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.IntStream;
import java.util.stream.LongStream;
import java.util.stream.Stream;

/**
 * Evaluates schedule expressions to compute occurrences.
 *
 * <p>A fixed time that falls in a DST gap shifts forward by the length of the gap (02:30 becomes
 * 03:30); an interval slot in a gap is skipped. A time that occurs twice at fall-back resolves to
 * the first occurrence. Only instants in [0001-01-02T00:00Z, 9999-12-30T00:00Z) are supported.
 */
public final class Evaluator {
  private static final Instant FIRST_INSTANT = Instant.parse("0001-01-02T00:00:00Z");

  private static final Instant END_INSTANT = Instant.parse("9999-12-30T00:00:00Z");

  // Local dates that can hold a supported instant in any zone, or its scheduled date when a DST
  // gap carries it past midnight.
  private static final LocalDate FIRST_DATE = LocalDate.of(0, 12, 31);

  private static final LocalDate LAST_DATE = LocalDate.of(9999, 12, 31);

  private static final LocalDate EPOCH_DATE = LocalDate.of(1970, 1, 1);

  private static final LocalDate EPOCH_MONDAY = LocalDate.of(1970, 1, 5);

  private Evaluator() {}

  /**
   * Computes the next occurrence strictly after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param location the timezone
   * @return the next occurrence, or empty if none exists or now is outside the supported range
   */
  public static Optional<ZonedDateTime> nextFrom(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    return isSupported(now) ? next(data, now, location) : Optional.empty();
  }

  /**
   * Computes the next n occurrences strictly after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param n the number of occurrences to compute
   * @param location the timezone
   * @return a list of the next n occurrences
   */
  public static List<ZonedDateTime> nextNFrom(
      ScheduleData data, ZonedDateTime now, int n, ZoneId location) {
    return occurrences(data, now, location).limit(Math.max(n, 0)).toList();
  }

  /**
   * Returns a lazy stream of occurrences strictly after the given time.
   *
   * @param data the schedule data
   * @param from the reference time (exclusive)
   * @param location the timezone
   * @return a stream of occurrences
   */
  public static Stream<ZonedDateTime> occurrences(
      ScheduleData data, ZonedDateTime from, ZoneId location) {
    return Stream.iterate(
            nextFrom(data, from, location), Optional::isPresent, t -> next(data, t.get(), location))
        .map(Optional::get);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @param data the schedule data
   * @param from the start time (exclusive)
   * @param to the end time (inclusive)
   * @param location the timezone
   * @return a stream of occurrences in the range, empty if to is outside the supported range
   */
  public static Stream<ZonedDateTime> between(
      ScheduleData data, ZonedDateTime from, ZonedDateTime to, ZoneId location) {
    if (!isSupported(to)) {
      return Stream.empty();
    }
    return occurrences(data, from, location).takeWhile(dt -> !dt.isAfter(to));
  }

  /**
   * Checks if the minute containing a datetime, on the schedule's wall clock, is an occurrence.
   *
   * @param data the schedule data
   * @param dt the datetime to check; its seconds are ignored
   * @param location the timezone
   * @return true if the datetime matches
   */
  public static boolean matches(ScheduleData data, ZonedDateTime dt, ZoneId location) {
    if (!isSupported(dt)) {
      return false;
    }
    ZonedDateTime minute = dt.withZoneSameInstant(location).truncatedTo(ChronoUnit.MINUTES);
    return isSupported(minute)
        && next(data, minute.minusNanos(1), location).filter(minute::isEqual).isPresent();
  }

  /**
   * Computes the most recent occurrence strictly before the given time.
   *
   * @param data the schedule data
   * @param now the reference time (exclusive upper bound)
   * @param location the timezone
   * @return the previous occurrence, or empty if none exists or now is outside the supported range
   */
  public static Optional<ZonedDateTime> previousFrom(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    if (!isSupported(now)) {
      return Optional.empty();
    }
    Clauses clauses = Clauses.of(data, now.toLocalDate());
    LocalDate searchFrom = now.toLocalDate();
    if (clauses.until() != null) {
      searchFrom = min(searchFrom, clauses.until());
    }
    LocalDate limit = searchLimit(data.expr(), searchFrom, false);
    if (clauses.starting() != null) {
      limit = max(limit, clauses.starting());
    }

    ZonedDateTime best = null;
    // A fall-back overlap that crosses midnight repeats the start of the next date before now.
    LocalDate start = now.toLocalDate().plusDays(1);
    if (clauses.until() != null) {
      start = min(start, clauses.until());
    }
    Iterator<LocalDate> days = scheduledDates(data, start, limit, false).iterator();
    while (days.hasNext()) {
      LocalDate day = days.next();
      // An occurrence scheduled on day lands before the start of the day after next.
      if (best != null && !day.plusDays(2).atStartOfDay(location).isAfter(best)) {
        break;
      }
      if (clauses.allow(day)) {
        Optional<ZonedDateTime> t = nearestOn(data.expr(), day, location, now, false);
        if (t.isPresent() && (best == null || t.get().isAfter(best))) {
          best = t.get();
        }
      }
    }
    return Optional.ofNullable(best).filter(Evaluator::isSupported);
  }

  private static Optional<ZonedDateTime> next(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    Clauses clauses = Clauses.of(data, now.toLocalDate());
    LocalDate searchFrom = now.toLocalDate();
    if (clauses.starting() != null) {
      searchFrom = max(searchFrom, clauses.starting());
    }
    LocalDate limit = searchLimit(data.expr(), searchFrom, true);
    if (clauses.until() != null) {
      limit = min(limit, clauses.until());
    }

    ZonedDateTime best = null;
    // A time shifted past midnight by a DST gap lands the day after its scheduled date.
    LocalDate start = now.toLocalDate().minusDays(1);
    if (clauses.starting() != null) {
      start = max(start, clauses.starting());
    }
    Iterator<LocalDate> days = scheduledDates(data, start, limit, true).iterator();
    while (days.hasNext()) {
      LocalDate day = days.next();
      if (best != null && !day.atStartOfDay(location).isBefore(best)) {
        break;
      }
      if (clauses.allow(day)) {
        Optional<ZonedDateTime> t = nearestOn(data.expr(), day, location, now, true);
        if (t.isPresent() && (best == null || t.get().isBefore(best))) {
          best = t.get();
        }
      }
    }
    return Optional.ofNullable(best).filter(Evaluator::isSupported);
  }

  private static boolean isSupported(ZonedDateTime t) {
    Instant instant = t.toInstant();
    return !instant.isBefore(FIRST_INSTANT) && instant.isBefore(END_INSTANT);
  }

  /**
   * The trailing clauses, resolved once per search. They see the scheduled date of a time shifted
   * past midnight by a DST gap and the landing date of a nearest weekday. A month repeat applies
   * during to its target month when listing dates instead, so its duringMonths is empty.
   */
  private record Clauses(
      LocalDate starting,
      LocalDate until,
      Set<Integer> duringMonths,
      Set<LocalDate> exceptDates,
      Set<MonthDay> exceptDays) {
    static Clauses of(ScheduleData data, LocalDate now) {
      Set<LocalDate> exceptDates = new HashSet<>();
      Set<MonthDay> exceptDays = new HashSet<>();
      for (ExceptionSpec exc : data.except()) {
        switch (exc.kind()) {
          case ISO -> exceptDates.add(LocalDate.parse(exc.date()));
          case NAMED -> exceptDays.add(MonthDay.of(exc.month().number(), exc.day()));
        }
      }
      return new Clauses(
          data.anchor() != null ? LocalDate.parse(data.anchor()) : null,
          data.until() != null ? resolveUntil(data.until(), now) : null,
          data.expr() instanceof MonthRepeat
              ? Set.of()
              : data.during().stream().map(MonthName::number).collect(Collectors.toSet()),
          exceptDates,
          exceptDays);
    }

    boolean allow(LocalDate day) {
      return (starting == null || !day.isBefore(starting))
          && (until == null || !day.isAfter(until))
          && (duringMonths.isEmpty() || duringMonths.contains(day.getMonthValue()))
          && !exceptDates.contains(day)
          && !exceptDays.contains(MonthDay.from(day));
    }
  }

  /**
   * Returns the last date a search from {@code from} needs to reach. The Gregorian calendar repeats
   * every 400 years, so a schedule repeats after lcm(400 years, its interval), and a search that
   * covers that span finds an occurrence if one exists.
   */
  private static LocalDate searchLimit(ScheduleExpr expr, LocalDate from, boolean forward) {
    long years =
        switch (expr) {
          case DayRepeat dr -> yearsToRepeat(146_097, dr.interval());
          case WeekRepeat wr -> yearsToRepeat(20_871, wr.interval());
          case MonthRepeat mr -> yearsToRepeat(4_800, mr.interval());
          case YearRepeat yr -> yearsToRepeat(400, yr.interval());
          case IntervalRepeat ir -> 400;
          case SingleDate sd -> 400;
        };
    if (forward) {
      return from.getYear() + years > LAST_DATE.getYear() ? LAST_DATE : from.plusYears(years);
    }
    return from.getYear() - years < FIRST_DATE.getYear() ? FIRST_DATE : from.minusYears(years);
  }

  /** Returns lcm(400 years, interval units) in years, given how many units make 400 years. */
  private static long yearsToRepeat(long unitsIn400Years, int interval) {
    return 400 * (interval / gcd(unitsIn400Years, interval));
  }

  private static long gcd(long a, long b) {
    return b == 0 ? a : gcd(b, a % b);
  }

  /**
   * Candidate scheduled dates from {@code from} towards {@code limit}, in search order. They are
   * aligned to the interval and pass the day filter and, for month repeats, during.
   */
  private static Stream<LocalDate> scheduledDates(
      ScheduleData data, LocalDate from, LocalDate limit, boolean forward) {
    int sign = forward ? 1 : -1;
    Comparator<LocalDate> order = forward ? Comparator.naturalOrder() : Comparator.reverseOrder();
    return switch (data.expr()) {
      case DayRepeat dr -> {
        LocalDate anchor = anchorDate(data.anchor(), EPOCH_DATE);
        long toAligned = alignStep(ChronoUnit.DAYS.between(from, anchor), dr.interval(), sign);
        yield Stream.iterate(
                from.plusDays(toAligned),
                d -> order.compare(d, limit) <= 0,
                d -> d.plusDays((long) sign * dr.interval()))
            .filter(d -> matchesDayFilter(d, dr.days()));
      }
      case IntervalRepeat ir ->
          Stream.iterate(from, d -> order.compare(d, limit) <= 0, d -> d.plusDays(sign))
              .filter(d -> ir.dayFilter() == null || matchesDayFilter(d, ir.dayFilter()));
      case WeekRepeat wr -> {
        LocalDate anchorMonday = monday(anchorDate(data.anchor(), EPOCH_MONDAY));
        LocalDate week = monday(from);
        long toAligned =
            alignStep(ChronoUnit.WEEKS.between(week, anchorMonday), wr.interval(), sign);
        List<Integer> dayOffsets =
            wr.weekDays().stream()
                .map(wd -> wd.number() - 1)
                .sorted(forward ? Comparator.naturalOrder() : Comparator.reverseOrder())
                .toList();
        yield Stream.iterate(
                week.plusWeeks(toAligned),
                w -> order.compare(forward ? w : w.plusDays(6), limit) <= 0,
                w -> w.plusWeeks((long) sign * wr.interval()))
            .flatMap(w -> dayOffsets.stream().map(w::plusDays));
      }
      case MonthRepeat mr -> {
        YearMonth anchorMonth = YearMonth.from(anchorDate(data.anchor(), EPOCH_DATE));
        // A nearest weekday can land up to two days outside its target month.
        YearMonth month = YearMonth.from(from).minusMonths(sign);
        long toAligned =
            alignStep(ChronoUnit.MONTHS.between(month, anchorMonth), mr.interval(), sign);
        yield Stream.iterate(
                month.plusMonths(toAligned),
                m ->
                    forward
                        ? !m.atDay(1).minusDays(2).isAfter(limit)
                        : !m.atEndOfMonth().plusDays(2).isBefore(limit),
                m -> m.plusMonths((long) sign * mr.interval()))
            .filter(m -> matchesDuring(m, data.during()))
            .flatMap(m -> getTargetDaysInMonth(m, mr.target()).stream().sorted(order));
      }
      case SingleDate sd -> {
        DateSpec spec = sd.dateSpec();
        yield switch (spec.kind()) {
          case ISO -> Stream.of(LocalDate.parse(spec.date()));
          case NAMED ->
              IntStream.iterate(
                      from.getYear(), y -> y * sign <= limit.getYear() * sign, y -> y + sign)
                  .mapToObj(y -> tryCreateDate(y, spec.month().number(), spec.day()))
                  .filter(Objects::nonNull);
        };
      }
      case YearRepeat yr -> {
        long anchorYear = anchorDate(data.anchor(), EPOCH_DATE).getYear();
        long first = from.getYear() + alignStep(anchorYear - from.getYear(), yr.interval(), sign);
        yield LongStream.iterate(
                first,
                y -> y * sign <= (long) limit.getYear() * sign,
                y -> y + (long) sign * yr.interval())
            .mapToObj(y -> getYearTargetDay((int) y, yr.target()))
            .flatMap(Optional::stream);
      }
    };
  }

  /**
   * Returns the signed step to the nearest aligned unit in the search direction, given the offset
   * to the anchor. Offsets before the anchor are negative multiples (floor, not truncation).
   */
  private static long alignStep(long offsetToAnchor, int interval, int sign) {
    return sign * Math.floorMod(sign * offsetToAnchor, interval);
  }

  /** Returns the occurrence scheduled on day nearest to now in the search direction. */
  private static Optional<ZonedDateTime> nearestOn(
      ScheduleExpr expr, LocalDate day, ZoneId zone, ZonedDateTime now, boolean forward) {
    return switch (expr) {
      case IntervalRepeat ir -> nearestSlot(ir, day, zone, now, forward);
      case DayRepeat dr -> nearestTime(dr.times(), day, zone, now, forward);
      case WeekRepeat wr -> nearestTime(wr.times(), day, zone, now, forward);
      case MonthRepeat mr -> nearestTime(mr.times(), day, zone, now, forward);
      case SingleDate sd -> nearestTime(sd.times(), day, zone, now, forward);
      case YearRepeat yr -> nearestTime(yr.times(), day, zone, now, forward);
    };
  }

  private static Optional<ZonedDateTime> nearestTime(
      List<TimeOfDay> times, LocalDate day, ZoneId zone, ZonedDateTime now, boolean forward) {
    Stream<ZonedDateTime> candidates =
        times.stream()
            .map(tod -> atTimeOnDate(day, tod, zone))
            .filter(t -> forward ? t.isAfter(now) : t.isBefore(now));
    Comparator<ZonedDateTime> byInstant = Comparator.comparing(ZonedDateTime::toInstant);
    return forward ? candidates.min(byInstant) : candidates.max(byInstant);
  }

  /**
   * Returns the interval slot on day nearest to now in the search direction. Placing a wall time at
   * its earliest instant, or at the end of the gap it falls in, never goes back in time as the wall
   * time advances, so a binary search finds the slot nearest to now; slots in a gap are then
   * skipped.
   */
  private static Optional<ZonedDateTime> nearestSlot(
      IntervalRepeat ir, LocalDate day, ZoneId zone, ZonedDateTime now, boolean forward) {
    long from = ir.fromTime().totalMinutes();
    long to = ir.toTime().totalMinutes();
    long step = (long) ir.interval() * (ir.unit() == IntervalUnit.MINUTES ? 1 : 60);
    if (to < from) {
      return Optional.empty();
    }
    long lastIndex = (to - from) / step;

    long low = 0;
    long high = lastIndex + 1;
    while (low < high) {
      long mid = (low + high) / 2;
      Instant t = instantOrGapEnd(day.atStartOfDay().plusMinutes(from + mid * step), zone);
      if (forward ? t.isAfter(now.toInstant()) : !t.isBefore(now.toInstant())) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }

    int direction = forward ? 1 : -1;
    for (long k = forward ? low : low - 1; k >= 0 && k <= lastIndex; k += direction) {
      Optional<ZonedDateTime> slot = intervalSlot(day, from + k * step, zone);
      if (slot.isPresent()) {
        return slot;
      }
    }
    return Optional.empty();
  }

  private static Instant instantOrGapEnd(LocalDateTime wallTime, ZoneId zone) {
    ZoneRules rules = zone.getRules();
    return rules.getValidOffsets(wallTime).isEmpty()
        ? rules.getTransition(wallTime).getInstant()
        : ZonedDateTime.of(wallTime, zone).toInstant();
  }

  private static LocalDate min(LocalDate a, LocalDate b) {
    return a.isBefore(b) ? a : b;
  }

  private static LocalDate max(LocalDate a, LocalDate b) {
    return a.isAfter(b) ? a : b;
  }

  private static LocalDate anchorDate(String anchor, LocalDate defaultAnchor) {
    return anchor != null ? LocalDate.parse(anchor) : defaultAnchor;
  }

  private static LocalDate monday(LocalDate date) {
    return date.minusDays(date.getDayOfWeek().getValue() - 1);
  }

  /** Returns the interval slot at a wall-clock minute, or empty if a DST gap skips it. */
  private static Optional<ZonedDateTime> intervalSlot(
      LocalDate date, long minuteOfDay, ZoneId location) {
    LocalDateTime slot = date.atStartOfDay().plusMinutes(minuteOfDay);
    if (location.getRules().getValidOffsets(slot).isEmpty()) {
      return Optional.empty();
    }
    return Optional.of(ZonedDateTime.of(slot, location));
  }

  private static boolean matchesDayFilter(LocalDate d, DayFilter f) {
    DayOfWeek dow = d.getDayOfWeek();
    return switch (f.kind()) {
      case EVERY -> true;
      case WEEKDAY -> dow.getValue() >= 1 && dow.getValue() <= 5;
      case WEEKEND -> dow.getValue() == 6 || dow.getValue() == 7;
      case DAYS -> {
        Weekday weekday = Weekday.fromDayOfWeek(dow);
        yield f.days().contains(weekday);
      }
    };
  }

  private static ZonedDateTime atTimeOnDate(LocalDate date, TimeOfDay tod, ZoneId location) {
    // ZonedDateTime.of shifts a time in a DST gap forward by the gap length and resolves a
    // fall-back overlap to the earlier offset, as spec/README.md "DST spring-forward (gaps)"
    // and "DST fall-back (ambiguous times)" require.
    return ZonedDateTime.of(date.atTime(tod.hour(), tod.minute()), location);
  }

  /** Returns the target dates for a month in ascending order. */
  private static List<LocalDate> getTargetDaysInMonth(YearMonth yearMonth, MonthTarget target) {
    int year = yearMonth.getYear();
    Month month = yearMonth.getMonth();
    return switch (target.kind()) {
      case LAST_DAY -> List.of(lastDayOfMonth(year, month));
      case LAST_WEEKDAY -> List.of(lastWeekdayOfMonth(year, month));
      case DAYS ->
          target.expandDays().stream()
              .filter(yearMonth::isValidDay)
              .distinct()
              .sorted()
              .map(yearMonth::atDay)
              .toList();
      case NEAREST_WEEKDAY -> {
        Optional<LocalDate> result =
            nearestWeekday(year, month, target.nearestWeekdayDay(), target.nearestDirection());
        yield result.map(List::of).orElse(List.of());
      }
      case ORDINAL_WEEKDAY -> {
        Optional<LocalDate> result =
            nthWeekdayOfMonth(year, month, target.weekday(), target.ordinal());
        yield result.map(List::of).orElse(List.of());
      }
    };
  }

  /**
   * Returns the weekday nearest to targetDay, or empty if the month has no such day. A null
   * direction never leaves the month (cron W); NEXT and PREVIOUS may.
   */
  private static Optional<LocalDate> nearestWeekday(
      int year, Month month, int targetDay, NearestDirection direction) {
    LocalDate last = lastDayOfMonth(year, month);
    int lastDayNum = last.getDayOfMonth();

    if (targetDay > lastDayNum) {
      return Optional.empty();
    }

    LocalDate date = LocalDate.of(year, month, targetDay);
    DayOfWeek dow = date.getDayOfWeek();

    if (dow != DayOfWeek.SATURDAY && dow != DayOfWeek.SUNDAY) {
      return Optional.of(date);
    }

    if (dow == DayOfWeek.SATURDAY) {
      if (direction == null) {
        if (targetDay == 1) {
          return Optional.of(date.plusDays(2));
        } else {
          return Optional.of(date.minusDays(1));
        }
      } else if (direction == NearestDirection.NEXT) {
        return Optional.of(date.plusDays(2));
      } else {
        return Optional.of(date.minusDays(1));
      }
    } else {
      if (direction == null) {
        if (targetDay >= lastDayNum) {
          return Optional.of(date.minusDays(2));
        } else {
          return Optional.of(date.plusDays(1));
        }
      } else if (direction == NearestDirection.NEXT) {
        return Optional.of(date.plusDays(1));
      } else {
        return Optional.of(date.minusDays(2));
      }
    }
  }

  private static Optional<LocalDate> nthWeekdayOfMonth(
      int year, Month month, Weekday weekday, OrdinalPosition ordinal) {
    if (ordinal == OrdinalPosition.LAST) {
      return Optional.of(lastWeekdayInMonth(year, month, weekday));
    }

    int n = ordinal.toN();
    DayOfWeek targetDow = weekday.toDayOfWeek();

    LocalDate d = LocalDate.of(year, month, 1);
    while (d.getDayOfWeek() != targetDow) {
      d = d.plusDays(1);
    }

    d = d.plusWeeks(n - 1);

    if (d.getMonth() != month) {
      return Optional.empty();
    }

    return Optional.of(d);
  }

  private static LocalDate lastDayOfMonth(int year, Month month) {
    return LocalDate.of(year, month, 1).plusMonths(1).minusDays(1);
  }

  private static LocalDate lastWeekdayOfMonth(int year, Month month) {
    LocalDate d = lastDayOfMonth(year, month);
    while (d.getDayOfWeek() == DayOfWeek.SATURDAY || d.getDayOfWeek() == DayOfWeek.SUNDAY) {
      d = d.minusDays(1);
    }
    return d;
  }

  private static LocalDate lastWeekdayInMonth(int year, Month month, Weekday weekday) {
    DayOfWeek targetDow = weekday.toDayOfWeek();
    LocalDate d = lastDayOfMonth(year, month);
    while (d.getDayOfWeek() != targetDow) {
      d = d.minusDays(1);
    }
    return d;
  }

  private static Optional<LocalDate> getYearTargetDay(int year, YearTarget target) {
    return switch (target.kind()) {
      case DATE, DAY_OF_MONTH ->
          Optional.ofNullable(tryCreateDate(year, target.month().number(), target.day()));
      case ORDINAL_WEEKDAY ->
          nthWeekdayOfMonth(year, target.month().toMonth(), target.weekday(), target.ordinal());
      case LAST_WEEKDAY -> Optional.of(lastWeekdayOfMonth(year, target.month().toMonth()));
    };
  }

  /** Tries to create a LocalDate, returning null if the date is invalid. */
  private static LocalDate tryCreateDate(int year, int month, int day) {
    try {
      return LocalDate.of(year, month, day);
    } catch (DateTimeException e) {
      return null;
    }
  }

  private static boolean matchesDuring(YearMonth month, List<MonthName> during) {
    return during.isEmpty() || during.stream().anyMatch(m -> m.number() == month.getMonthValue());
  }

  private static LocalDate resolveUntil(UntilSpec until, LocalDate now) {
    return switch (until.kind()) {
      case ISO -> LocalDate.parse(until.date());
      case NAMED -> {
        int year = now.getYear();
        LocalDate d = LocalDate.of(year, until.month().number(), until.day());
        if (d.isBefore(now)) {
          d = LocalDate.of(year + 1, until.month().number(), until.day());
        }
        yield d;
      }
    };
  }
}
