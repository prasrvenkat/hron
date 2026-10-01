package io.hron.eval;

import io.hron.ast.DateSpec;
import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.MonthRepeat;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.WeekRepeat;
import io.hron.ast.YearRepeat;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.Iterator;
import java.util.List;
import java.util.stream.LongStream;

/**
 * The periods (days, weeks, months or years) an expression fires in, numbered from {@code origin}:
 * period {@code k} is aligned when {@code k} is a multiple of {@code interval}. A single ISO date
 * has one period, the one holding that date.
 */
record Cadence(Unit unit, LocalDate origin, long interval, boolean single) {
  /** Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment"). */
  static final LocalDate EPOCH_MONDAY = LocalDate.of(1970, 1, 5);

  /** Default anchor for day, month and year intervals. */
  static final LocalDate EPOCH_DATE = LocalDate.of(1970, 1, 1);

  /**
   * Slack beyond the horizon for the period one behind the first date's, where a search starts, and
   * for a horizon that starts mid-period.
   */
  static final long HORIZON_MARGIN_PERIODS = 2;

  /**
   * Every period holding an occurrence in the supported range, in any zone, holds a date from
   * FIRST_DATE to LAST_DATE, allowing for a DST shift past midnight and a nearest weekday two days
   * outside its period. LocalDate reaches far beyond them, so they are the edges of the calendar a
   * search walks.
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
    LocalDate anchor = starting != null ? starting : unit == Unit.WEEK ? EPOCH_MONDAY : EPOCH_DATE;
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
      case MONTH -> monthIndex(date) - monthIndex(origin);
      case YEAR -> date.getYear() - origin.getYear();
    };
  }

  /** First day of period {@code k}. */
  LocalDate startOf(long k) {
    return switch (unit) {
      case DAY -> origin.plusDays(k);
      case WEEK -> origin.plusWeeks(k);
      case MONTH -> origin.plusMonths(k);
      case YEAR -> origin.plusYears(k);
    };
  }

  /**
   * The first days of the aligned periods from {@code firstPeriod} in {@code direction}, through
   * one search horizon beyond whichever of {@code firstPeriod} and {@code reach} is farther along
   * it (spec/README.md, "Search horizon"), leaving out those holding no date from FIRST_DATE to
   * LAST_DATE.
   */
  Iterator<LocalDate> periodStarts(long firstPeriod, long reach, Direction direction) {
    if (single) {
      return List.of(origin).iterator();
    }
    long first = align(firstPeriod, direction);
    long beyond = direction.sign() * (align(reach, direction) - first);
    long count = horizonPeriods() + HORIZON_MARGIN_PERIODS + Math.max(beyond, 0) / interval;
    boolean forward = direction == Direction.FORWARD;
    long toNearEdge = direction.sign() * (periodOf(forward ? FIRST_DATE : LAST_DATE) - first);
    long toFarEdge = direction.sign() * (periodOf(forward ? LAST_DATE : FIRST_DATE) - first);
    long skip = Math.max(0, Math.ceilDiv(toNearEdge, interval));
    long end = Math.min(count, Math.floorDiv(toFarEdge, interval) + 1);
    long step = direction.sign() * interval;
    return LongStream.range(skip, end).mapToObj(i -> startOf(first + i * step)).iterator();
  }

  /** The first aligned period at or beyond period {@code k} in {@code direction}. */
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

  /** Months since January of year 0. */
  private static long monthIndex(LocalDate date) {
    return date.getYear() * 12L + date.getMonthValue() - 1;
  }

  private static long gcd(long a, long b) {
    return b == 0 ? a : gcd(b, a % b);
  }
}
