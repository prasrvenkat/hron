package io.hron.internal.eval;

import io.hron.Schedule;
import io.hron.ast.ExceptionSpec;
import io.hron.ast.MonthName;
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
 * `during`", "The `starting` clause").
 */
record Clauses(
    Set<Month> during,
    Set<MonthDay> exceptMonthDays,
    NavigableSet<LocalDate> exceptDates,
    LocalDate until,
    LocalDate starting) {
  /** Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29. */
  static final int NAMED_UNTIL_MAX_YEARS = 8;

  static Clauses of(Schedule schedule, LocalDate starting) {
    Set<Month> during = EnumSet.noneOf(Month.class);
    for (MonthName month : schedule.during()) {
      during.add(month.toMonth());
    }
    Set<MonthDay> exceptMonthDays = new HashSet<>();
    NavigableSet<LocalDate> exceptDates = new TreeSet<>();
    for (ExceptionSpec exception : schedule.except()) {
      switch (exception.kind()) {
        case NAMED -> exceptMonthDays.add(MonthDay.of(exception.month().number(), exception.day()));
        case ISO -> exceptDates.add(LocalDate.parse(exception.date()));
      }
    }
    LocalDate until = schedule.until().map(u -> resolveUntil(u, starting)).orElse(null);
    return new Clauses(during, exceptMonthDays, exceptDates, until, starting);
  }

  boolean allows(Candidate candidate) {
    LocalDate date = candidate.date();
    return allowsMonth(candidate.targetMonth())
        && !exceptMonthDays.contains(MonthDay.from(date))
        && !exceptDates.contains(date)
        && (until == null || !date.isAfter(until))
        && (starting == null || !date.isBefore(starting));
  }

  boolean allowsMonth(Month month) {
    return during.isEmpty() || during.contains(month);
  }

  Clauses endOn(LocalDate date) {
    LocalDate end = until == null || date.isBefore(until) ? date : until;
    return new Clauses(during, exceptMonthDays, exceptDates, end, starting);
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

  LocalDate clamp(LocalDate date, Direction direction) {
    LocalDate bound = direction == Direction.FORWARD ? starting : until;
    return bound != null && direction.precedes(date, bound) ? bound : date;
  }

  boolean endsSearch(LocalDate date, Direction direction) {

    LocalDate bound = direction == Direction.FORWARD ? until : starting;
    return bound != null && direction.precedes(bound, date);
  }

  /**
   * A named until date is the first such date on or after the starting date (spec/README.md, "Named
   * `until`"), which a named until always has.
   */
  private static LocalDate resolveUntil(UntilSpec until, LocalDate starting) {
    return switch (until.kind()) {
      case ISO -> LocalDate.parse(until.date());
      case NAMED -> {
        for (int k = 0; k <= NAMED_UNTIL_MAX_YEARS; k++) {
          Optional<LocalDate> date =
              CalendarDates.dateOf(starting.getYear() + k, until.month().number(), until.day());
          if (date.isPresent() && !date.get().isBefore(starting)) {
            yield date.get();
          }
        }
        // Unreached: parse rejects a day its month never has, and any other recurs within
        // NAMED_UNTIL_MAX_YEARS. A null until leaves the schedule unbounded.
        yield null;
      }
    };
  }
}
