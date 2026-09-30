package io.hron.eval;

import io.hron.ast.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Objects;
import java.util.Optional;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.stream.IntStream;
import java.util.stream.LongStream;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

/**
 * Evaluates schedule expressions to compute occurrences.
 *
 * <p>A fixed time that falls in a DST gap shifts forward by the length of the gap (02:30 becomes
 * 03:30); an interval slot in a gap is skipped. A time that occurs twice at fall-back resolves to
 * the first occurrence.
 */
public final class Evaluator {
  private static final int FIRST_YEAR = 1;

  private static final int LAST_YEAR = 9999;

  private static final LocalDate EPOCH_DATE = LocalDate.of(1970, 1, 1);

  private static final LocalDate EPOCH_MONDAY = LocalDate.of(1970, 1, 5);

  private Evaluator() {}

  /**
   * Computes the next occurrence strictly after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param location the timezone
   * @return the next occurrence, or empty if none exists
   */
  public static Optional<ZonedDateTime> nextFrom(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    LocalDate untilDate = untilDate(data, now.toLocalDate());
    LocalDate limit = searchLimit(data.expr(), now.toLocalDate(), true);
    if (untilDate != null && untilDate.isBefore(limit)) {
      limit = untilDate;
    }

    ZonedDateTime best = null;
    // A time shifted past midnight by a DST gap lands the day after its scheduled date.
    Iterator<LocalDate> days = datesForward(data, now.toLocalDate().minusDays(1), limit).iterator();
    while (days.hasNext()) {
      LocalDate day = days.next();
      if (best != null && !day.atStartOfDay(location).isBefore(best)) {
        break;
      }
      if (!clausesAllow(data, day, untilDate)) {
        continue;
      }
      for (ZonedDateTime t : occurrencesOn(data.expr(), day, location)) {
        if (t.isAfter(now)) {
          if (best == null || t.isBefore(best)) {
            best = t;
          }
          break;
        }
      }
    }
    return Optional.ofNullable(best).filter(t -> t.getYear() <= LAST_YEAR);
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
    List<ZonedDateTime> results = new ArrayList<>();
    ZonedDateTime current = now;

    for (int i = 0; i < n; i++) {
      Optional<ZonedDateTime> next = nextFrom(data, current, location);
      if (next.isEmpty()) {
        break;
      }
      results.add(next.get());
      current = next.get();
    }

    return results;
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
    Iterator<ZonedDateTime> iterator =
        new Iterator<>() {
          private ZonedDateTime current = from;
          private ZonedDateTime next = null;
          private boolean hasNext = false;
          private boolean computed = false;

          private void computeNext() {
            if (!computed) {
              Optional<ZonedDateTime> result = nextFrom(data, current, location);
              if (result.isPresent()) {
                next = result.get();
                current = next;
                hasNext = true;
              } else {
                hasNext = false;
              }
              computed = true;
            }
          }

          @Override
          public boolean hasNext() {
            computeNext();
            return hasNext;
          }

          @Override
          public ZonedDateTime next() {
            computeNext();
            if (!hasNext) {
              throw new NoSuchElementException();
            }
            computed = false;
            return next;
          }
        };

    return StreamSupport.stream(
        Spliterators.spliteratorUnknownSize(iterator, Spliterator.ORDERED | Spliterator.NONNULL),
        false);
  }

  /**
   * Returns a lazy stream of occurrences where from &lt; occurrence &lt;= to.
   *
   * @param data the schedule data
   * @param from the start time (exclusive)
   * @param to the end time (inclusive)
   * @param location the timezone
   * @return a stream of occurrences in the range
   */
  public static Stream<ZonedDateTime> between(
      ScheduleData data, ZonedDateTime from, ZonedDateTime to, ZoneId location) {
    return occurrences(data, from, location).takeWhile(dt -> !dt.isAfter(to));
  }

  /**
   * Checks if the minute containing a datetime is an occurrence, using structural matching.
   *
   * @param data the schedule data
   * @param dt the datetime to check; its seconds are ignored
   * @param location the timezone
   * @return true if the datetime matches
   */
  public static boolean matches(ScheduleData data, ZonedDateTime dt, ZoneId location) {
    ZonedDateTime minute = dt.withZoneSameInstant(location).truncatedTo(ChronoUnit.MINUTES);
    LocalDate date = minute.toLocalDate();

    if (date.getYear() < FIRST_YEAR || date.getYear() > LAST_YEAR) {
      return false;
    }
    // A time shifted past midnight by a DST gap keeps its scheduled date, the day before.
    return isOccurrenceOn(data, date, minute, location)
        || isOccurrenceOn(data, date.minusDays(1), minute, location);
  }

  private static boolean isOccurrenceOn(
      ScheduleData data, LocalDate day, ZonedDateTime minute, ZoneId location) {
    return clausesAllow(data, day, untilDate(data, day))
        && isScheduledOn(data, day, minute, location);
  }

  private static boolean isScheduledOn(
      ScheduleData data, LocalDate date, ZonedDateTime minute, ZoneId location) {
    return switch (data.expr()) {
      case DayRepeat dr -> {
        if (!matchesDayFilter(date, dr.days()) || !timeMatches(date, dr.times(), minute)) {
          yield false;
        }
        if (dr.interval() > 1) {
          LocalDate anchorDate = anchorDate(data.anchor(), EPOCH_DATE);
          yield isAligned(ChronoUnit.DAYS.between(anchorDate, date), dr.interval(), data.anchor());
        }
        yield true;
      }
      case IntervalRepeat ir -> {
        if (ir.dayFilter() != null && !matchesDayFilter(date, ir.dayFilter())) {
          yield false;
        }
        int fromMinutes = ir.fromTime().totalMinutes();
        int currentMinutes = minute.getHour() * 60 + minute.getMinute();
        if (currentMinutes < fromMinutes
            || currentMinutes > ir.toTime().totalMinutes()
            || (currentMinutes - fromMinutes) % intervalStep(ir) != 0) {
          yield false;
        }
        yield intervalSlot(date, currentMinutes, location)
            .filter(slot -> slot.isEqual(minute))
            .isPresent();
      }
      case WeekRepeat wr -> {
        Weekday wd = Weekday.fromDayOfWeek(date.getDayOfWeek());
        if (!wr.weekDays().contains(wd) || !timeMatches(date, wr.times(), minute)) {
          yield false;
        }
        LocalDate anchorMonday = monday(anchorDate(data.anchor(), EPOCH_MONDAY));
        long weeks = ChronoUnit.WEEKS.between(anchorMonday, monday(date));
        yield isAligned(weeks, wr.interval(), data.anchor());
      }
      case MonthRepeat mr ->
          timeMatches(date, mr.times(), minute)
              && isMonthRepeatDate(date, mr, data.anchor(), data.during());
      case SingleDate sd -> {
        if (!timeMatches(date, sd.times(), minute)) {
          yield false;
        }
        yield switch (sd.dateSpec().kind()) {
          case ISO -> date.equals(LocalDate.parse(sd.dateSpec().date()));
          case NAMED ->
              date.getMonthValue() == sd.dateSpec().month().number()
                  && date.getDayOfMonth() == sd.dateSpec().day();
        };
      }
      case YearRepeat yr -> {
        if (!timeMatches(date, yr.times(), minute)) {
          yield false;
        }
        if (yr.interval() > 1) {
          int anchorYear = anchorDate(data.anchor(), EPOCH_DATE).getYear();
          if (!isAligned(date.getYear() - anchorYear, yr.interval(), data.anchor())) {
            yield false;
          }
        }
        yield matchesYearTarget(date, yr.target());
      }
    };
  }

  /**
   * Whether offset is a whole number of intervals from the anchor. Nothing before an explicit
   * starting date is aligned; before the default epoch anchor, offsets are negative multiples.
   */
  private static boolean isAligned(long offset, int interval, String anchor) {
    return (anchor == null || offset >= 0) && Math.floorMod(offset, interval) == 0;
  }

  private static boolean timeMatches(LocalDate date, List<TimeOfDay> times, ZonedDateTime minute) {
    return times.stream()
        .anyMatch(tod -> atTimeOnDate(date, tod, minute.getZone()).isEqual(minute));
  }

  /** A nearest weekday can land in the month before or after the month whose day it targets. */
  private static boolean isMonthRepeatDate(
      LocalDate date, MonthRepeat mr, String anchor, List<MonthName> during) {
    YearMonth anchorMonth = YearMonth.from(anchorDate(anchor, EPOCH_DATE));
    YearMonth landing = YearMonth.from(date);
    for (YearMonth month : List.of(landing.minusMonths(1), landing, landing.plusMonths(1))) {
      if (matchesDuring(month, during)
          && (mr.interval() == 1
              || isAligned(ChronoUnit.MONTHS.between(anchorMonth, month), mr.interval(), anchor))
          && getTargetDaysInMonth(month, mr.target()).contains(date)) {
        return true;
      }
    }
    return false;
  }

  private static boolean matchesYearTarget(LocalDate date, YearTarget target) {
    return switch (target.kind()) {
      case DATE ->
          date.getMonthValue() == target.month().number() && date.getDayOfMonth() == target.day();
      case ORDINAL_WEEKDAY -> {
        if (date.getMonthValue() != target.month().number()) {
          yield false;
        }
        Optional<LocalDate> ord =
            nthWeekdayOfMonth(date.getYear(), date.getMonth(), target.weekday(), target.ordinal());
        yield ord.isPresent() && date.equals(ord.get());
      }
      case DAY_OF_MONTH ->
          date.getMonthValue() == target.month().number() && date.getDayOfMonth() == target.day();
      case LAST_WEEKDAY -> {
        if (date.getMonthValue() != target.month().number()) {
          yield false;
        }
        yield date.equals(lastWeekdayOfMonth(date.getYear(), date.getMonth()));
      }
    };
  }

  /**
   * Computes the most recent occurrence strictly before the given time.
   *
   * @param data the schedule data
   * @param now the reference time (exclusive upper bound)
   * @param location the timezone
   * @return the previous occurrence, or empty if none exists
   */
  public static Optional<ZonedDateTime> previousFrom(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    LocalDate untilDate = untilDate(data, now.toLocalDate());
    LocalDate start = now.toLocalDate();
    if (untilDate != null && untilDate.isBefore(start)) {
      start = untilDate;
    }
    LocalDate limit = searchLimit(data.expr(), start, false);
    if (data.anchor() != null && limit.isBefore(LocalDate.parse(data.anchor()))) {
      limit = LocalDate.parse(data.anchor());
    }

    ZonedDateTime best = null;
    Iterator<LocalDate> days = datesBackward(data, start, limit).iterator();
    while (days.hasNext()) {
      LocalDate day = days.next();
      // An occurrence on day lands before the start of the day after next.
      if (best != null && !day.plusDays(2).atStartOfDay(location).isAfter(best)) {
        break;
      }
      if (!clausesAllow(data, day, untilDate)) {
        continue;
      }
      for (ZonedDateTime t : occurrencesOn(data.expr(), day, location).reversed()) {
        if (t.isBefore(now)) {
          if (best == null || t.isAfter(best)) {
            best = t;
          }
          break;
        }
      }
    }
    return Optional.ofNullable(best).filter(t -> t.getYear() >= FIRST_YEAR);
  }

  /**
   * Whether the except, until and during clauses allow an occurrence scheduled on day. A time
   * shifted past midnight by a DST gap keeps its scheduled date; a month repeat applies during to
   * its target month when enumerating dates instead.
   */
  private static boolean clausesAllow(ScheduleData data, LocalDate day, LocalDate untilDate) {
    return !isExcepted(day, data.except())
        && (untilDate == null || !day.isAfter(untilDate))
        && (data.expr() instanceof MonthRepeat || matchesDuring(day, data.during()));
  }

  private static LocalDate untilDate(ScheduleData data, LocalDate now) {
    return data.until() != null ? resolveUntil(data.until(), now) : null;
  }

  /**
   * Returns the last date a search from {@code from} needs to reach, within years 1 to 9999. The
   * Gregorian calendar repeats every 400 years, so a schedule repeats after lcm(400 years, its
   * interval), and a search that covers that span finds an occurrence if one exists.
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
      return from.getYear() + years > LAST_YEAR
          ? LocalDate.of(LAST_YEAR, 12, 31)
          : from.plusYears(years);
    }
    return from.getYear() - years < FIRST_YEAR
        ? LocalDate.of(FIRST_YEAR, 1, 1)
        : from.minusYears(years);
  }

  /** Returns lcm(400 years, interval units) in years, given how many units make 400 years. */
  private static long yearsToRepeat(long unitsIn400Years, int interval) {
    return 400 * (interval / gcd(unitsIn400Years, interval));
  }

  private static long gcd(long a, long b) {
    return b == 0 ? a : gcd(b, a % b);
  }

  /** Returns the occurrences scheduled on a date, ordered by instant. */
  private static List<ZonedDateTime> occurrencesOn(ScheduleExpr expr, LocalDate day, ZoneId zone) {
    return switch (expr) {
      case DayRepeat dr -> timesOn(day, dr.times(), zone);
      case WeekRepeat wr -> timesOn(day, wr.times(), zone);
      case MonthRepeat mr -> timesOn(day, mr.times(), zone);
      case SingleDate sd -> timesOn(day, sd.times(), zone);
      case YearRepeat yr -> timesOn(day, yr.times(), zone);
      case IntervalRepeat ir -> {
        List<ZonedDateTime> slots = new ArrayList<>();
        for (int m = ir.fromTime().totalMinutes();
            m <= ir.toTime().totalMinutes();
            m += intervalStep(ir)) {
          intervalSlot(day, m, zone).ifPresent(slots::add);
        }
        yield slots;
      }
    };
  }

  private static List<ZonedDateTime> timesOn(LocalDate day, List<TimeOfDay> times, ZoneId zone) {
    return times.stream()
        .map(tod -> atTimeOnDate(day, tod, zone))
        .sorted(Comparator.comparing(ZonedDateTime::toInstant))
        .toList();
  }

  /** Candidate scheduled dates from {@code from} up to {@code limit}, in ascending order. */
  private static Stream<LocalDate> datesForward(
      ScheduleData data, LocalDate from, LocalDate limit) {
    String anchor = data.anchor();
    return switch (data.expr()) {
      case DayRepeat dr -> {
        LocalDate anchorDate = anchorDate(anchor, EPOCH_DATE);
        LocalDate first =
            from.plusDays(Math.floorMod(ChronoUnit.DAYS.between(from, anchorDate), dr.interval()));
        yield Stream.iterate(first, d -> !d.isAfter(limit), d -> d.plusDays(dr.interval()))
            .filter(d -> matchesDayFilter(d, dr.days()));
      }
      case IntervalRepeat ir ->
          Stream.iterate(from, d -> !d.isAfter(limit), d -> d.plusDays(1))
              .filter(d -> ir.dayFilter() == null || matchesDayFilter(d, ir.dayFilter()));
      case WeekRepeat wr -> {
        LocalDate anchorMonday = monday(anchorDate(anchor, EPOCH_MONDAY));
        LocalDate week = monday(from);
        long weeks = ChronoUnit.WEEKS.between(anchorMonday, week);
        LocalDate first =
            anchor != null && weeks < 0
                ? anchorMonday
                : week.plusWeeks(Math.floorMod(-weeks, wr.interval()));
        List<Weekday> days =
            wr.weekDays().stream().sorted(Comparator.comparing(Weekday::number)).toList();
        yield Stream.iterate(first, w -> !w.isAfter(limit), w -> w.plusWeeks(wr.interval()))
            .flatMap(w -> days.stream().map(wd -> w.plusDays(wd.number() - 1)));
      }
      case MonthRepeat mr -> {
        // A nearest weekday can land in the month before or after its target month.
        YearMonth anchorMonth = YearMonth.from(anchorDate(anchor, EPOCH_DATE));
        YearMonth month = YearMonth.from(from).minusMonths(1);
        YearMonth first =
            month.plusMonths(
                Math.floorMod(ChronoUnit.MONTHS.between(month, anchorMonth), mr.interval()));
        yield Stream.iterate(
                first,
                m -> !m.minusMonths(1).atEndOfMonth().isAfter(limit),
                m -> m.plusMonths(mr.interval()))
            .filter(m -> matchesDuring(m, data.during()))
            .flatMap(m -> getTargetDaysInMonth(m, mr.target()).stream());
      }
      case SingleDate sd -> singleDates(sd, from.getYear(), limit.getYear());
      case YearRepeat yr -> {
        long anchorYear = anchorDate(anchor, EPOCH_DATE).getYear();
        long first = from.getYear() + Math.floorMod(anchorYear - from.getYear(), yr.interval());
        yield LongStream.iterate(first, y -> y <= limit.getYear(), y -> y + yr.interval())
            .mapToObj(y -> getYearTargetDay((int) y, yr.target()))
            .flatMap(Optional::stream);
      }
    };
  }

  /** Mirrors {@link #datesForward}: candidate dates from {@code from} down to {@code limit}. */
  private static Stream<LocalDate> datesBackward(
      ScheduleData data, LocalDate from, LocalDate limit) {
    String anchor = data.anchor();
    return switch (data.expr()) {
      case DayRepeat dr -> {
        LocalDate anchorDate = anchorDate(anchor, EPOCH_DATE);
        LocalDate first =
            from.minusDays(Math.floorMod(ChronoUnit.DAYS.between(anchorDate, from), dr.interval()));
        yield Stream.iterate(first, d -> !d.isBefore(limit), d -> d.minusDays(dr.interval()))
            .filter(d -> matchesDayFilter(d, dr.days()));
      }
      case IntervalRepeat ir ->
          Stream.iterate(from, d -> !d.isBefore(limit), d -> d.minusDays(1))
              .filter(d -> ir.dayFilter() == null || matchesDayFilter(d, ir.dayFilter()));
      case WeekRepeat wr -> {
        LocalDate anchorMonday = monday(anchorDate(anchor, EPOCH_MONDAY));
        LocalDate week = monday(from);
        LocalDate first =
            week.minusWeeks(
                Math.floorMod(ChronoUnit.WEEKS.between(anchorMonday, week), wr.interval()));
        List<Weekday> days =
            wr.weekDays().stream()
                .sorted(Comparator.comparing(Weekday::number).reversed())
                .toList();
        yield Stream.iterate(
                first, w -> !w.plusDays(6).isBefore(limit), w -> w.minusWeeks(wr.interval()))
            .flatMap(w -> days.stream().map(wd -> w.plusDays(wd.number() - 1)));
      }
      case MonthRepeat mr -> {
        // A nearest weekday can land in the month before or after its target month.
        YearMonth anchorMonth = YearMonth.from(anchorDate(anchor, EPOCH_DATE));
        YearMonth month = YearMonth.from(from).plusMonths(1);
        YearMonth first =
            month.minusMonths(
                Math.floorMod(ChronoUnit.MONTHS.between(anchorMonth, month), mr.interval()));
        yield Stream.iterate(
                first,
                m -> !m.plusMonths(1).atDay(1).isBefore(limit),
                m -> m.minusMonths(mr.interval()))
            .filter(m -> matchesDuring(m, data.during()))
            .flatMap(m -> getTargetDaysInMonth(m, mr.target()).reversed().stream());
      }
      case SingleDate sd -> singleDates(sd, from.getYear(), limit.getYear());
      case YearRepeat yr -> {
        long anchorYear = anchorDate(anchor, EPOCH_DATE).getYear();
        long first = from.getYear() - Math.floorMod(from.getYear() - anchorYear, yr.interval());
        yield LongStream.iterate(first, y -> y >= limit.getYear(), y -> y - yr.interval())
            .mapToObj(y -> getYearTargetDay((int) y, yr.target()))
            .flatMap(Optional::stream);
      }
    };
  }

  /** The dates of a single date from year {@code from} to year {@code to}, in that order. */
  private static Stream<LocalDate> singleDates(SingleDate sd, int from, int to) {
    DateSpec spec = sd.dateSpec();
    return switch (spec.kind()) {
      case ISO -> Stream.of(LocalDate.parse(spec.date()));
      case NAMED -> {
        int step = from <= to ? 1 : -1;
        yield IntStream.iterate(from, y -> y != to + step, y -> y + step)
            .mapToObj(y -> tryCreateDate(y, spec.month().number(), spec.day()))
            .filter(Objects::nonNull);
      }
    };
  }

  private static LocalDate anchorDate(String anchor, LocalDate defaultAnchor) {
    return anchor != null ? LocalDate.parse(anchor) : defaultAnchor;
  }

  private static LocalDate monday(LocalDate date) {
    return date.minusDays(date.getDayOfWeek().getValue() - 1);
  }

  private static int intervalStep(IntervalRepeat ir) {
    return ir.interval() * (ir.unit() == IntervalUnit.MINUTES ? 1 : 60);
  }

  /** Returns the interval slot at a wall-clock minute, or empty if a DST gap skips it. */
  private static Optional<ZonedDateTime> intervalSlot(
      LocalDate date, int minuteOfDay, ZoneId location) {
    LocalDateTime slot = date.atTime(minuteOfDay / 60, minuteOfDay % 60);
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
      case DATE -> {
        try {
          yield Optional.of(LocalDate.of(year, target.month().number(), target.day()));
        } catch (DateTimeException e) {
          yield Optional.empty();
        }
      }
      case ORDINAL_WEEKDAY ->
          nthWeekdayOfMonth(year, target.month().toMonth(), target.weekday(), target.ordinal());
      case DAY_OF_MONTH -> {
        try {
          yield Optional.of(LocalDate.of(year, target.month().number(), target.day()));
        } catch (DateTimeException e) {
          yield Optional.empty();
        }
      }
      case LAST_WEEKDAY -> Optional.of(lastWeekdayOfMonth(year, target.month().toMonth()));
    };
  }

  private static LocalDate resolveDate(DateSpec spec, LocalDate now) {
    return switch (spec.kind()) {
      case ISO -> LocalDate.parse(spec.date());
      case NAMED -> {
        LocalDate d = tryCreateDate(now.getYear(), spec.month().number(), spec.day());
        if (d == null || d.isBefore(now)) {
          d = tryCreateDate(now.getYear() + 1, spec.month().number(), spec.day());
        }
        yield d;
      }
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

  private static boolean isExcepted(LocalDate d, List<ExceptionSpec> exceptions) {
    for (ExceptionSpec exc : exceptions) {
      switch (exc.kind()) {
        case NAMED -> {
          if (d.getMonthValue() == exc.month().number() && d.getDayOfMonth() == exc.day()) {
            return true;
          }
        }
        case ISO -> {
          LocalDate excDate = LocalDate.parse(exc.date());
          if (d.equals(excDate)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  private static boolean matchesDuring(LocalDate d, List<MonthName> during) {
    return matchesDuring(YearMonth.from(d), during);
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
