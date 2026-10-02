package io.hron.internal.eval;

import io.hron.ast.DateSpec;
import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.MonthRepeat;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.WeekRepeat;
import io.hron.ast.YearRepeat;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.temporal.ChronoUnit;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Objects;
import java.util.function.LongPredicate;

record Cadence(Unit unit, LocalDate origin, long interval, boolean single) {
  /** Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment"). */
  static final LocalDate EPOCH_MONDAY = LocalDate.of(1970, 1, 5);

  static final LocalDate EPOCH_DATE = LocalDate.of(1970, 1, 1);

  /**
   * Slack beyond the horizon for the period one behind the first date's, where a search starts, and
   * for a horizon that starts mid-period.
   */
  static final long HORIZON_MARGIN_PERIODS = 2;

  /**
   * Every period holding an occurrence in the supported range, in any zone, holds a date from
   * FIRST_DATE to LAST_DATE, allowing for a DST shift past midnight and a nearest weekday two days
   * outside its period. So they are the edges of the calendar a search walks, which also keeps it
   * inside LocalDate's own range: past year 999,999,999, which a huge interval reaches, {@link
   * LocalDate#plusYears} throws.
   */
  private static final LocalDate FIRST_DATE = LocalDate.of(0, 12, 29);

  private static final LocalDate LAST_DATE = LocalDate.of(10000, 1, 1);

  enum Unit {
    DAY(146_097),
    WEEK(20_871),
    MONTH(4_800),
    YEAR(400);

    /** Units in 400 years, after which the proleptic Gregorian calendar repeats. */
    final long per400Years;

    Unit(long per400Years) {
      this.per400Years = per400Years;
    }
  }

  static Cadence of(ScheduleExpr expr, LocalDate starting) {
    return switch (expr) {
      case SingleDate sd when sd.dateSpec().kind() == DateSpec.Kind.ISO ->
          new Cadence(Unit.DAY, LocalDate.parse(sd.dateSpec().date()), 1, true);
      case SingleDate _ -> repeating(Unit.YEAR, 1, starting);
      case IntervalRepeat _ -> repeating(Unit.DAY, 1, starting);
      case DayRepeat dr -> repeating(Unit.DAY, dr.interval(), starting);
      case WeekRepeat wr -> repeating(Unit.WEEK, wr.interval(), starting);
      case MonthRepeat mr -> repeating(Unit.MONTH, mr.interval(), starting);
      case YearRepeat yr -> repeating(Unit.YEAR, yr.interval(), starting);
    };
  }

  private static Cadence repeating(Unit unit, int interval, LocalDate starting) {
    LocalDate anchor =
        Objects.requireNonNullElse(starting, unit == Unit.WEEK ? EPOCH_MONDAY : EPOCH_DATE);
    LocalDate origin =
        switch (unit) {
          case DAY -> anchor;
          case WEEK -> CalendarDates.mondayOf(anchor);
          case MONTH -> anchor.withDayOfMonth(1);
          case YEAR -> anchor.withDayOfYear(1);
        };
    return new Cadence(unit, origin, interval, false);
  }

  long periodOf(LocalDate date) {
    return switch (unit) {
      case DAY -> ChronoUnit.DAYS.between(origin, date);
      case WEEK -> Math.floorDiv(ChronoUnit.DAYS.between(origin, date), 7);
      case MONTH -> ChronoUnit.MONTHS.between(YearMonth.from(origin), YearMonth.from(date));
      case YEAR -> date.getYear() - origin.getYear();
    };
  }

  LocalDate startOf(long k) {
    return switch (unit) {
      case DAY -> origin.plusDays(k);
      case WEEK -> origin.plusWeeks(k);
      case MONTH -> origin.plusMonths(k);
      case YEAR -> origin.plusYears(k);
    };
  }

  /** spec/README.md, "Search horizon". */
  Iterable<LocalDate> periodStarts(long firstPeriod, long reach, Direction direction) {
    if (single) {
      return List.of(origin);
    }
    long first = align(firstPeriod, direction);
    long beyond = direction.sign() * (align(reach, direction) - first);
    long count = horizonPeriods() + HORIZON_MARGIN_PERIODS + Math.max(beyond, 0) / interval;
    long step = direction.sign() * interval;
    long firstInCalendar = periodOf(FIRST_DATE);
    long lastInCalendar = periodOf(LAST_DATE);
    LongPredicate inCalendar = k -> firstInCalendar <= k && k <= lastInCalendar;
    // The periods' dropWhile(not inCalendar), then takeWhile(inCalendar), without the cost a
    // stream pipeline adds to every search.
    return () ->
        new Iterator<>() {
          private long k = first;
          private long left = count;

          {
            while (left > 0 && !inCalendar.test(k)) {
              k += step;
              left--;
            }
          }

          @Override
          public boolean hasNext() {
            return left > 0 && inCalendar.test(k);
          }

          @Override
          public LocalDate next() {
            if (!hasNext()) {
              throw new NoSuchElementException();
            }
            LocalDate start = startOf(k);
            k += step;
            left--;
            return start;
          }
        };
  }

  long align(long k, Direction direction) {

    return switch (direction) {
      case FORWARD -> k + Math.floorMod(-k, interval);
      case BACKWARD -> k - Math.floorMod(k, interval);
    };
  }

  /**
   * Aligned periods in lcm(400 years, interval units), after which both the calendar and the
   * alignment repeat.
   */
  long horizonPeriods() {
    return unit.per400Years / gcd(unit.per400Years, interval);
  }

  private static long gcd(long a, long b) {
    return b == 0 ? a : gcd(b, a % b);
  }
}
