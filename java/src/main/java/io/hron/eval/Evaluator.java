package io.hron.eval;

import io.hron.ast.*;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Optional;
import java.util.Spliterator;
import java.util.Spliterators;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;

/** Evaluates schedule expressions to compute next occurrences. */
public final class Evaluator {
  /** Maximum iterations to prevent infinite loops. */
  private static final int MAX_ITERATIONS = 1000;

  /** Epoch date for day/month/year alignment. */
  private static final LocalDate EPOCH_DATE = LocalDate.of(1970, 1, 1);

  /** Epoch Monday for week alignment. */
  private static final LocalDate EPOCH_MONDAY = LocalDate.of(1970, 1, 5);

  private Evaluator() {}

  /**
   * Computes the next occurrence after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param location the timezone
   * @return the next occurrence, or empty if none exists
   */
  public static Optional<ZonedDateTime> nextFrom(
      ScheduleData data, ZonedDateTime now, ZoneId location) {
    // Check if expression is NearestWeekday with direction (can cross month boundaries)
    // For these expressions, during filter is handled inside nextMonthRepeat
    boolean handlesDuringInternally = false;
    if (data.expr() instanceof MonthRepeat mr
        && mr.target().kind() == MonthTarget.Kind.NEAREST_WEEKDAY
        && mr.target().nearestDirection() != null) {
      handlesDuringInternally = true;
    }

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      Optional<ZonedDateTime> candidate =
          nextCandidate(data.expr(), now, location, data.anchor(), data.during());
      if (candidate.isEmpty()) {
        return Optional.empty();
      }

      ZonedDateTime t = candidate.get();

      // Apply modifiers
      // Check exception list
      if (isExcepted(t.toLocalDate(), data.except())) {
        now = t;
        continue;
      }

      // Check until date
      if (data.until() != null) {
        LocalDate untilDate = resolveUntil(data.until(), now.toLocalDate());
        if (t.toLocalDate().isAfter(untilDate)) {
          return Optional.empty();
        }
      }

      // Check during clause (skip for expressions that handle during internally)
      if (!handlesDuringInternally && !matchesDuring(t.toLocalDate(), data.during())) {
        // Skip to next month that matches
        LocalDate nextMonth = nextDuringMonth(t.toLocalDate(), data.during());
        now = ZonedDateTime.of(nextMonth, LocalTime.MIDNIGHT, location).minusNanos(1);
        continue;
      }

      return Optional.of(t);
    }

    return Optional.empty();
  }

  /**
   * Computes the next n occurrences after the given time.
   *
   * @param data the schedule data
   * @param now the reference time
   * @param n the number of occurrences to compute
   * @param location the timezone
   * @return a list of the next n occurrences
   */
  public static List<ZonedDateTime> nextNFrom(
      ScheduleData data, ZonedDateTime now, int n, ZoneId location) {
    List<ZonedDateTime> results = new ArrayList<>(n);
    ZonedDateTime current = now;

    for (int i = 0; i < n && i < MAX_ITERATIONS; i++) {
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
   * Returns a lazy stream of occurrences starting after the given time.
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
                current = next.plusMinutes(1);
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
   * Returns a lazy stream of occurrences where from < occurrence <= to.
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
   * Checks if a datetime matches the schedule.
   *
   * @param data the schedule data
   * @param dt the datetime to check
   * @param location the timezone
   * @return true if the datetime matches
   */
  public static boolean matches(ScheduleData data, ZonedDateTime dt, ZoneId location) {
    // Check slightly before to see if the next occurrence is at dt
    ZonedDateTime beforeDt = dt.minusNanos(1);
    Optional<ZonedDateTime> next = nextFrom(data, beforeDt, location);
    return next.isPresent() && next.get().equals(dt);
  }

  private static Optional<ZonedDateTime> nextCandidate(
      ScheduleExpr expr,
      ZonedDateTime now,
      ZoneId location,
      String anchor,
      List<MonthName> during) {
    return switch (expr) {
      case DayRepeat dr -> nextDayRepeat(dr, now, location, anchor);
      case IntervalRepeat ir -> nextIntervalRepeat(ir, now, location);
      case WeekRepeat wr -> nextWeekRepeat(wr, now, location, anchor);
      case MonthRepeat mr -> nextMonthRepeat(mr, now, location, anchor, during);
      case OrdinalRepeat or -> nextOrdinalRepeat(or, now, location, anchor);
      case SingleDate sd -> nextSingleDate(sd, now, location);
      case YearRepeat yr -> nextYearRepeat(yr, now, location, anchor);
    };
  }

  private static Optional<ZonedDateTime> nextDayRepeat(
      DayRepeat dr, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_DATE;
    LocalDate day = now.toLocalDate();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      if (dr.interval() > 1) {
        // Check alignment
        long daysFromAnchor = ChronoUnit.DAYS.between(anchorDate, day);
        long mod = daysFromAnchor % dr.interval();
        if (mod < 0) mod += dr.interval();
        if (mod != 0) {
          day = day.plusDays(dr.interval() - mod);
          continue;
        }
      }

      if (matchesDayFilter(day, dr.days())) {
        Optional<ZonedDateTime> time = earliestFutureTime(day, dr.times(), location, now);
        if (time.isPresent()) {
          return time;
        }
      }

      day = day.plusDays(dr.interval() > 1 ? dr.interval() : 1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextIntervalRepeat(
      IntervalRepeat ir, ZonedDateTime now, ZoneId location) {
    LocalDate day = now.toLocalDate();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      if (ir.dayFilter() != null && !matchesDayFilter(day, ir.dayFilter())) {
        day = day.plusDays(1);
        continue;
      }

      int fromMinutes = ir.fromTime().totalMinutes();
      int toMinutes = ir.toTime().totalMinutes();

      // Find starting point in the window
      int nowMinutes = now.toLocalDate().equals(day) ? now.getHour() * 60 + now.getMinute() : -1;

      // Iterate through the window
      for (int m = fromMinutes;
          m <= toMinutes;
          m += ir.interval() * (ir.unit() == IntervalUnit.MINUTES ? 1 : 60)) {
        int hour = m / 60;
        int minute = m % 60;
        ZonedDateTime t = atTimeOnDate(day, new TimeOfDay(hour, minute), location);

        if (t.isAfter(now)) {
          return Optional.of(t);
        }
      }

      day = day.plusDays(1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextWeekRepeat(
      WeekRepeat wr, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_MONDAY;
    // Find Monday of anchor date
    LocalDate anchorMonday = anchorDate.minusDays(anchorDate.getDayOfWeek().getValue() - 1);

    LocalDate day = now.toLocalDate();
    // Find Monday of current week
    LocalDate currentMonday = day.minusDays(day.getDayOfWeek().getValue() - 1);

    // Sort target weekdays for earliest-first matching
    List<Weekday> sortedDays = new ArrayList<>(wr.weekDays());
    sortedDays.sort((a, b) -> Integer.compare(a.number(), b.number()));

    for (int i = 0; i < 54; i++) {
      long daysBetween = ChronoUnit.DAYS.between(anchorMonday, currentMonday);
      long weeks = daysBetween / 7;

      // Skip weeks before anchor
      // When weeks_since_anchor < 0, anchorMonday is in the future
      // Use anchorMonday directly as the first aligned week
      if (weeks < 0) {
        currentMonday = anchorMonday;
        continue;
      }

      if (weeks % wr.interval() == 0) {
        // Aligned week — try each target weekday
        for (Weekday wd : sortedDays) {
          int dayOffset = wd.number() - 1; // Monday=1, so offset = 0 for Monday
          LocalDate targetDate = currentMonday.plusDays(dayOffset);
          Optional<ZonedDateTime> time = earliestFutureTime(targetDate, wr.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
      }

      // Skip to next aligned week
      long remainder = weeks % wr.interval();
      long skipWeeks = wr.interval();
      if (remainder != 0) {
        skipWeeks = wr.interval() - remainder;
      }
      currentMonday = currentMonday.plusWeeks(skipWeeks);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextMonthRepeat(
      MonthRepeat mr, ZonedDateTime now, ZoneId location, String anchor, List<MonthName> during) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_DATE;
    LocalDate day = now.toLocalDate();

    // For NearestWeekday with direction, apply during filter here (on source month)
    boolean applyDuringFilter =
        !during.isEmpty()
            && mr.target().kind() == MonthTarget.Kind.NEAREST_WEEKDAY
            && mr.target().nearestDirection() != null;

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      // Check during filter for NearestWeekday with direction
      if (applyDuringFilter && !matchesDuring(day.withDayOfMonth(1), during)) {
        LocalDate nextMonth = nextDuringMonth(day, during);
        day = nextMonth;
        continue;
      }

      // Check month alignment
      if (mr.interval() > 1) {
        long monthsFromAnchor =
            ChronoUnit.MONTHS.between(anchorDate.withDayOfMonth(1), day.withDayOfMonth(1));
        long mod = monthsFromAnchor % mr.interval();
        if (mod < 0) mod += mr.interval();
        if (mod != 0) {
          day = day.withDayOfMonth(1).plusMonths(mr.interval() - mod);
          continue;
        }
      }

      // Get target days for this month
      List<LocalDate> targetDays = getTargetDaysInMonth(day.getYear(), day.getMonth(), mr.target());

      // For directional NearestWeekday, the result can be in a different month
      // (e.g., "previous nearest weekday to 1st" in March -> Feb 27)
      // Don't skip based on `day` for these - earliestFutureTime handles the now check
      boolean canCrossMonth =
          mr.target().kind() == MonthTarget.Kind.NEAREST_WEEKDAY
              && mr.target().nearestDirection() != null;

      for (LocalDate targetDay : targetDays) {
        if (!canCrossMonth && targetDay.isBefore(day)) continue;

        Optional<ZonedDateTime> time = earliestFutureTime(targetDay, mr.times(), location, now);
        if (time.isPresent()) {
          return time;
        }
      }

      // Move to next month
      day = day.withDayOfMonth(1).plusMonths(mr.interval() > 1 ? mr.interval() : 1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextOrdinalRepeat(
      OrdinalRepeat or, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_DATE;
    LocalDate day = now.toLocalDate();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      // Check month alignment
      if (or.interval() > 1) {
        long monthsFromAnchor =
            ChronoUnit.MONTHS.between(anchorDate.withDayOfMonth(1), day.withDayOfMonth(1));
        long mod = monthsFromAnchor % or.interval();
        if (mod < 0) mod += or.interval();
        if (mod != 0) {
          day = day.withDayOfMonth(1).plusMonths(or.interval() - mod);
          continue;
        }
      }

      // Find the ordinal weekday in this month
      Optional<LocalDate> targetDay =
          nthWeekdayOfMonth(day.getYear(), day.getMonth(), or.weekday(), or.ordinal());

      if (targetDay.isPresent() && !targetDay.get().isBefore(day)) {
        Optional<ZonedDateTime> time =
            earliestFutureTime(targetDay.get(), or.times(), location, now);
        if (time.isPresent()) {
          return time;
        }
      }

      // Move to next month
      day = day.withDayOfMonth(1).plusMonths(or.interval() > 1 ? or.interval() : 1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextSingleDate(
      SingleDate sd, ZonedDateTime now, ZoneId location) {
    int startYear = now.getYear();

    switch (sd.dateSpec().kind()) {
      case ISO -> {
        LocalDate d = LocalDate.parse(sd.dateSpec().date());
        return earliestFutureTime(d, sd.times(), location, now);
      }
      case NAMED -> {
        for (int y = 0; y < 8; y++) {
          int year = startYear + y;
          LocalDate d = tryCreateDate(year, sd.dateSpec().month().number(), sd.dateSpec().day());
          // Skip invalid dates (e.g., Feb 30)
          if (d == null) {
            continue;
          }
          Optional<ZonedDateTime> time = earliestFutureTime(d, sd.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
        return Optional.empty();
      }
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> nextYearRepeat(
      YearRepeat yr, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_DATE;
    int year = now.getYear();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      // Check year alignment
      if (yr.interval() > 1) {
        long yearsFromAnchor = year - anchorDate.getYear();
        long mod = yearsFromAnchor % yr.interval();
        if (mod < 0) mod += yr.interval();
        if (mod != 0) {
          year += yr.interval() - mod;
          continue;
        }
      }

      Optional<LocalDate> targetDay = getYearTargetDay(year, yr.target());

      if (targetDay.isPresent()) {
        LocalDate day = targetDay.get();
        if (!day.isBefore(now.toLocalDate())) {
          Optional<ZonedDateTime> time = earliestFutureTime(day, yr.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
      }

      year += yr.interval() > 1 ? yr.interval() : 1;
    }

    return Optional.empty();
  }

  // Helper methods

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

  private static Optional<ZonedDateTime> earliestFutureTime(
      LocalDate day, List<TimeOfDay> times, ZoneId location, ZonedDateTime now) {
    ZonedDateTime best = null;
    for (TimeOfDay tod : times) {
      ZonedDateTime candidate = atTimeOnDate(day, tod, location);
      if (candidate.isAfter(now)) {
        if (best == null || candidate.isBefore(best)) {
          best = candidate;
        }
      }
    }
    return Optional.ofNullable(best);
  }

  /**
   * Creates a ZonedDateTime at the given date and time in the given timezone. Handles DST: spring
   * forward pushes non-existent times forward.
   */
  private static ZonedDateTime atTimeOnDate(LocalDate date, TimeOfDay tod, ZoneId location) {
    LocalDateTime ldt = LocalDateTime.of(date, LocalTime.of(tod.hour(), tod.minute()));

    // Java's ZonedDateTime.of handles DST gaps by pushing forward
    // But the default is to use the EARLIER offset for fall-back
    // We need to match the Go behavior of using the first occurrence
    ZonedDateTime zdt = ZonedDateTime.of(ldt, location);

    // Check if we're in a gap (spring forward)
    // The ZonedDateTime will have adjusted the time - we want to check if adjustment happened
    if (zdt.getHour() != tod.hour() || zdt.getMinute() != tod.minute()) {
      // We're in a DST gap, find the correct time after the gap
      // This is the behavior from Go's implementation
      int requestedMinutes = tod.hour() * 60 + tod.minute();
      int gotMinutes = zdt.getHour() * 60 + zdt.getMinute();
      int gapMinutes = requestedMinutes - gotMinutes;

      if (gapMinutes > 0) {
        // Push forward past the gap
        zdt = zdt.plusMinutes(gapMinutes);
      }
    }

    return zdt;
  }

  private static List<LocalDate> getTargetDaysInMonth(int year, Month month, MonthTarget target) {
    return switch (target.kind()) {
      case LAST_DAY -> List.of(lastDayOfMonth(year, month));
      case LAST_WEEKDAY -> List.of(lastWeekdayOfMonth(year, month));
      case DAYS -> {
        List<LocalDate> days = new ArrayList<>();
        for (int day : target.expandDays()) {
          try {
            LocalDate d = LocalDate.of(year, month, day);
            days.add(d);
          } catch (DateTimeException e) {
            // Skip invalid days (e.g., Feb 30)
          }
        }
        yield days;
      }
      case NEAREST_WEEKDAY -> {
        Optional<LocalDate> result =
            nearestWeekday(year, month, target.nearestWeekdayDay(), target.nearestDirection());
        yield result.map(List::of).orElse(List.of());
      }
    };
  }

  /**
   * Computes the nearest weekday to a given day in a month.
   *
   * <ul>
   *   <li>direction=null: standard cron W behavior (never crosses month boundary)
   *   <li>direction=NEXT: always prefer following weekday (can cross to next month)
   *   <li>direction=PREVIOUS: always prefer preceding weekday (can cross to prev month)
   * </ul>
   *
   * @param year the year
   * @param month the month
   * @param targetDay the target day of month (1-31)
   * @param direction the direction, or null for standard behavior
   * @return the nearest weekday date, or empty if target day doesn't exist in the month
   */
  private static Optional<LocalDate> nearestWeekday(
      int year, Month month, int targetDay, NearestDirection direction) {
    LocalDate last = lastDayOfMonth(year, month);
    int lastDayNum = last.getDayOfMonth();

    // If target day doesn't exist in this month, return empty (skip this month)
    if (targetDay > lastDayNum) {
      return Optional.empty();
    }

    LocalDate date = LocalDate.of(year, month, targetDay);
    DayOfWeek dow = date.getDayOfWeek();

    // Already a weekday
    if (dow != DayOfWeek.SATURDAY && dow != DayOfWeek.SUNDAY) {
      return Optional.of(date);
    }

    if (dow == DayOfWeek.SATURDAY) {
      if (direction == null) {
        // Standard: prefer Friday, but if at month start, use Monday
        if (targetDay == 1) {
          // Can't go to previous month, use Monday (day 3)
          return Optional.of(date.plusDays(2));
        } else {
          // Friday
          return Optional.of(date.minusDays(1));
        }
      } else if (direction == NearestDirection.NEXT) {
        // Always Monday (may cross month)
        return Optional.of(date.plusDays(2));
      } else {
        // PREVIOUS: Always Friday (may cross month if day==1)
        return Optional.of(date.minusDays(1));
      }
    } else {
      // Sunday
      if (direction == null) {
        // Standard: prefer Monday, but if at month end, use Friday
        if (targetDay >= lastDayNum) {
          // Can't go to next month, use Friday (day - 2)
          return Optional.of(date.minusDays(2));
        } else {
          // Monday
          return Optional.of(date.plusDays(1));
        }
      } else if (direction == NearestDirection.NEXT) {
        // Always Monday (may cross month)
        return Optional.of(date.plusDays(1));
      } else {
        // PREVIOUS: Always Friday (go back 2 days, may cross month)
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
        // Try current year first, handling invalid dates (e.g., Feb 29 in non-leap year)
        LocalDate d = tryCreateDate(now.getYear(), spec.month().number(), spec.day());
        if (d == null || d.isBefore(now)) {
          // Try next year
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
    if (during.isEmpty()) {
      return true;
    }
    for (MonthName m : during) {
      if (d.getMonthValue() == m.number()) {
        return true;
      }
    }
    return false;
  }

  private static LocalDate nextDuringMonth(LocalDate d, List<MonthName> during) {
    int currentMonth = d.getMonthValue();

    // Sort months
    List<Integer> months = during.stream().map(MonthName::number).sorted().toList();

    // Find next month after current
    for (int m : months) {
      if (m > currentMonth) {
        return LocalDate.of(d.getYear(), m, 1);
      }
    }

    // Wrap to first month of next year
    return LocalDate.of(d.getYear() + 1, months.getFirst(), 1);
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
