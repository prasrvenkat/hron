package io.hron.eval;

import io.hron.ast.ExceptionSpec;
import io.hron.ast.MonthName;
import io.hron.ast.ScheduleData;
import io.hron.ast.UntilSpec;
import java.time.LocalDate;
import java.time.Month;
import java.time.MonthDay;
import java.util.EnumSet;
import java.util.HashSet;
import java.util.NavigableSet;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;

/**
 * The trailing clauses, resolved once. {@code during} applies to a candidate's target month; {@code
 * except}, {@code until} and {@code starting} to its date (spec/README.md, "Nearest weekday and
 * `during`", "The `starting` clause"). A null {@code until} or {@code starting} is no bound, and an
 * empty {@code during} allows every month.
 */
record Clauses(
    Set<Month> during,
    Set<MonthDay> exceptMonthDays,
    NavigableSet<LocalDate> exceptDates,
    LocalDate until,
    LocalDate starting) {
  /** Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29. */
  static final int NAMED_UNTIL_MAX_YEARS = 8;

  static Clauses of(ScheduleData data, LocalDate starting) {
    Set<Month> during = EnumSet.noneOf(Month.class);
    for (MonthName month : data.during()) {
      during.add(month.toMonth());
    }
    Set<MonthDay> exceptMonthDays = new HashSet<>();
    NavigableSet<LocalDate> exceptDates = new TreeSet<>();
    for (ExceptionSpec exception : data.except()) {
      switch (exception.kind()) {
        case NAMED -> exceptMonthDays.add(MonthDay.of(exception.month().number(), exception.day()));
        case ISO -> exceptDates.add(LocalDate.parse(exception.date()));
      }
    }
    LocalDate until = data.until() == null ? null : resolveUntil(data.until(), starting);
    return new Clauses(during, exceptMonthDays, exceptDates, until, starting);
  }

  boolean allows(Candidate candidate) {
    LocalDate date = candidate.date();
    return (during.isEmpty() || during.contains(candidate.targetMonth()))
        && !exceptMonthDays.contains(MonthDay.from(date))
        && !exceptDates.contains(date)
        && (until == null || !date.isAfter(until))
        && (starting == null || !date.isBefore(starting));
  }

  /**
   * The one-off except date farthest along {@code direction}: the calendar repeats only beyond it
   * (spec/README.md, "Search horizon").
   */
  Optional<LocalDate> farthestExceptDate(Direction direction) {
    if (exceptDates.isEmpty()) {
      return Optional.empty();
    }
    return Optional.of(direction == Direction.FORWARD ? exceptDates.last() : exceptDates.first());
  }

  /**
   * The date a search starts from: nothing fires before {@code starting} or after {@code until}.
   */
  LocalDate clamp(LocalDate date, Direction direction) {
    LocalDate bound = direction == Direction.FORWARD ? starting : until;
    return bound != null && direction.precedes(date, bound) ? bound : date;
  }

  /**
   * Whether {@code date}, and every date beyond it in {@code direction}, is past the bound the
   * search moves toward.
   */
  boolean endsSearch(LocalDate date, Direction direction) {
    LocalDate bound = direction == Direction.FORWARD ? until : starting;
    return bound != null && direction.precedes(bound, date);
  }

  /**
   * A named until date is the first such date on or after the starting date (spec/README.md, "Named
   * `until`"). Parse requires {@code starting}; a schedule built without one resolves from the
   * default anchor, the epoch.
   */
  private static LocalDate resolveUntil(UntilSpec until, LocalDate starting) {
    return switch (until.kind()) {
      case ISO -> LocalDate.parse(until.date());
      case NAMED -> {
        LocalDate from = starting != null ? starting : Cadence.EPOCH_DATE;
        for (int k = 0; k <= NAMED_UNTIL_MAX_YEARS; k++) {
          Optional<LocalDate> date =
              CalendarDates.dateOf(from.getYear() + k, until.month().number(), until.day());
          if (date.isPresent() && !date.get().isBefore(from)) {
            yield date.get();
          }
        }
        yield null;
      }
    };
  }
}
