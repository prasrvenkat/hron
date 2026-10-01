package io.hron.eval;

import io.hron.ast.DayFilter;
import io.hron.ast.MonthTarget;
import io.hron.ast.NearestDirection;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.Weekday;
import io.hron.ast.YearTarget;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.YearMonth;
import java.time.temporal.TemporalAdjusters;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/** Date arithmetic on the proleptic Gregorian calendar: no time zones, no schedules. */
final class CalendarDates {
  private CalendarDates() {}

  static LocalDate mondayOf(LocalDate date) {
    return date.with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY));
  }

  /** {@code day} of {@code month} of {@code year}, or empty when that month is shorter. */
  static Optional<LocalDate> dateOf(int year, int month, int day) {
    YearMonth yearMonth = YearMonth.of(year, month);
    return yearMonth.isValidDay(day) ? Optional.of(yearMonth.atDay(day)) : Optional.empty();
  }

  static boolean matchesDayFilter(LocalDate date, DayFilter filter) {
    return switch (filter.kind()) {
      case EVERY -> true;
      case WEEKDAY -> !isWeekend(date);
      case WEEKEND -> isWeekend(date);
      case DAYS -> filter.days().contains(Weekday.fromDayOfWeek(date.getDayOfWeek()));
    };
  }

  private static boolean isWeekend(LocalDate date) {
    DayOfWeek day = date.getDayOfWeek();
    return day == DayOfWeek.SATURDAY || day == DayOfWeek.SUNDAY;
  }

  /** The dates a monthly target names in {@code month}, earliest first. */
  static List<LocalDate> monthTargetDates(YearMonth month, MonthTarget target) {
    return switch (target.kind()) {
      case DAYS -> daysOfMonth(month, target.expandDays());
      case LAST_DAY -> List.of(month.atEndOfMonth());
      case LAST_WEEKDAY -> List.of(lastWeekdayOfMonth(month));
      case NEAREST_WEEKDAY ->
          nearestWeekday(month, target.nearestWeekdayDay(), target.nearestDirection()).stream()
              .toList();
      case ORDINAL_WEEKDAY ->
          ordinalWeekday(month, target.ordinal(), target.weekday()).stream().toList();
    };
  }

  /** The {@code days} that {@code month} has, earliest first and each once. */
  private static List<LocalDate> daysOfMonth(YearMonth month, List<Integer> days) {
    long named = 0;
    for (int day : days) {
      if (month.isValidDay(day)) {
        named |= 1L << day;
      }
    }
    List<LocalDate> dates = new ArrayList<>(days.size());
    for (int day = 1; day <= month.lengthOfMonth(); day++) {
      if ((named & 1L << day) != 0) {
        dates.add(month.atDay(day));
      }
    }
    return dates;
  }

  static Optional<LocalDate> yearTargetDate(int year, YearTarget target) {
    YearMonth month = YearMonth.of(year, target.month().number());
    return switch (target.kind()) {
      case DATE, DAY_OF_MONTH -> dateOf(year, target.month().number(), target.day());
      case ORDINAL_WEEKDAY -> ordinalWeekday(month, target.ordinal(), target.weekday());
      case LAST_WEEKDAY -> Optional.of(lastWeekdayOfMonth(month));
    };
  }

  /** The last Monday to Friday of {@code month}. */
  private static LocalDate lastWeekdayOfMonth(YearMonth month) {
    LocalDate last = month.atEndOfMonth();
    int back =
        switch (last.getDayOfWeek()) {
          case SATURDAY -> 1;
          case SUNDAY -> 2;
          default -> 0;
        };
    return last.minusDays(back);
  }

  private static Optional<LocalDate> ordinalWeekday(
      YearMonth month, OrdinalPosition ordinal, Weekday weekday) {
    LocalDate date =
        month
            .atDay(1)
            .with(TemporalAdjusters.dayOfWeekInMonth(ordinal.toN(), weekday.toDayOfWeek()));
    return YearMonth.from(date).equals(month) ? Optional.of(date) : Optional.empty();
  }

  /**
   * The weekday nearest {@code day} of {@code month}, or empty when the month is shorter. Without a
   * direction it stays in the month, as cron's {@code W} does; with one it can cross into the
   * adjacent month (spec/README.md, "Nearest weekday and `during`").
   */
  private static Optional<LocalDate> nearestWeekday(
      YearMonth month, int day, NearestDirection toward) {
    if (!month.isValidDay(day)) {
      return Optional.empty();
    }
    LocalDate date = month.atDay(day);
    int shift =
        switch (date.getDayOfWeek()) {
          case SATURDAY ->
              switch (toward) {
                case NEXT -> 2;
                case PREVIOUS -> -1;
                case null -> day == 1 ? 2 : -1;
              };
          case SUNDAY ->
              switch (toward) {
                case NEXT -> 1;
                case PREVIOUS -> -2;
                case null -> day == month.lengthOfMonth() ? -2 : 1;
              };
          default -> 0;
        };
    return Optional.of(date.plusDays(shift));
  }
}
