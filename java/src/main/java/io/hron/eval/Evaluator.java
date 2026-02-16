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

/**
 * Evaluates schedule expressions to compute next occurrences.
 *
 * <h2>Iteration Safety Limits</h2>
 *
 * <p>MAX_ITERATIONS (1000): Maximum iterations for nextFrom/previousFrom loops. Prevents infinite
 * loops when searching for valid occurrences.
 *
 * <p>Expression-specific limits:
 *
 * <ul>
 *   <li>Day repeat: 8 days (covers one week + margin)
 *   <li>Week repeat: 54 weeks (covers one year + margin)
 *   <li>Month repeat: 24 * interval months (covers 2 years scaled by interval)
 *   <li>Year repeat: 8 * interval years (covers reasonable future horizon)
 * </ul>
 *
 * <p>These limits are generous safety bounds. In practice, valid schedules find occurrences within
 * the first few iterations.
 *
 * <h2>DST (Daylight Saving Time) Handling</h2>
 *
 * <p>When resolving a wall-clock time to an instant:
 *
 * <ol>
 *   <li><b>DST Gap (Spring Forward):</b> Time doesn't exist (e.g., 2:30 AM during spring forward).
 *       Solution: Push forward to the next valid time after the gap.
 *   <li><b>DST Fold (Fall Back):</b> Time is ambiguous (e.g., 1:30 AM occurs twice). Solution: Use
 *       first occurrence (pre-transition time).
 * </ol>
 *
 * <p>All implementations use the same algorithm for cross-language consistency.
 *
 * <h2>Interval Alignment (Anchor Date)</h2>
 *
 * <p>For schedules with interval &gt; 1 (e.g., "every 3 days"), we determine which dates are valid
 * based on alignment with an anchor.
 *
 * <p>Formula: (date_offset - anchor_offset) mod interval == 0
 *
 * <ul>
 *   <li>date_offset: days/weeks/months from epoch to candidate date
 *   <li>anchor_offset: days/weeks/months from epoch to anchor date
 *   <li>interval: the repeat interval (e.g., 3 for "every 3 days")
 * </ul>
 *
 * <p>Default anchor: Epoch (1970-01-01). Custom anchor: Set via "starting YYYY-MM-DD" clause.
 *
 * <p>For week repeats, we use epoch Monday (1970-01-05) as the reference point.
 */
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
   * Checks if a datetime matches the schedule using structural matching.
   *
   * @param data the schedule data
   * @param dt the datetime to check
   * @param location the timezone
   * @return true if the datetime matches
   */
  public static boolean matches(ScheduleData data, ZonedDateTime dt, ZoneId location) {
    ZonedDateTime zdt = dt.withZoneSameInstant(location);
    LocalDate date = zdt.toLocalDate();

    // Check during filter
    if (!matchesDuring(date, data.during())) {
      return false;
    }

    // Check exceptions
    if (isExcepted(date, data.except())) {
      return false;
    }

    // Check until
    if (data.until() != null) {
      LocalDate untilDate = resolveUntil(data.until(), date);
      if (date.isAfter(untilDate)) {
        return false;
      }
    }

    return switch (data.expr()) {
      case DayRepeat dr -> {
        if (!matchesDayFilter(date, dr.days())) {
          yield false;
        }
        if (!timeMatchesWithDst(date, dr.times(), location, dt)) {
          yield false;
        }
        if (dr.interval() > 1) {
          LocalDate anchorDate =
              data.anchor() != null ? LocalDate.parse(data.anchor()) : EPOCH_DATE;
          long dayOffset = ChronoUnit.DAYS.between(anchorDate, date);
          yield dayOffset >= 0 && dayOffset % dr.interval() == 0;
        }
        yield true;
      }
      case IntervalRepeat ir -> {
        if (ir.dayFilter() != null && !matchesDayFilter(date, ir.dayFilter())) {
          yield false;
        }
        int fromMinutes = ir.fromTime().totalMinutes();
        int toMinutes = ir.toTime().totalMinutes();
        int currentMinutes = zdt.getHour() * 60 + zdt.getMinute();
        if (currentMinutes < fromMinutes || currentMinutes > toMinutes) {
          yield false;
        }
        int diff = currentMinutes - fromMinutes;
        int step = ir.interval() * (ir.unit() == IntervalUnit.MINUTES ? 1 : 60);
        yield diff >= 0 && diff % step == 0;
      }
      case WeekRepeat wr -> {
        Weekday wd = Weekday.fromDayOfWeek(date.getDayOfWeek());
        if (!wr.weekDays().contains(wd)) {
          yield false;
        }
        if (!timeMatchesWithDst(date, wr.times(), location, dt)) {
          yield false;
        }
        LocalDate anchorDate =
            data.anchor() != null ? LocalDate.parse(data.anchor()) : EPOCH_MONDAY;
        long weeks = ChronoUnit.DAYS.between(anchorDate, date) / 7;
        yield weeks >= 0 && weeks % wr.interval() == 0;
      }
      case MonthRepeat mr -> {
        if (!timeMatchesWithDst(date, mr.times(), location, dt)) {
          yield false;
        }
        if (mr.interval() > 1) {
          LocalDate anchorDate =
              data.anchor() != null ? LocalDate.parse(data.anchor()) : EPOCH_DATE;
          long monthOffset =
              ChronoUnit.MONTHS.between(anchorDate.withDayOfMonth(1), date.withDayOfMonth(1));
          if (monthOffset < 0 || monthOffset % mr.interval() != 0) {
            yield false;
          }
        }
        yield matchesMonthTarget(date, mr.target());
      }
      case SingleDate sd -> {
        if (!timeMatchesWithDst(date, sd.times(), location, dt)) {
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
        if (!timeMatchesWithDst(date, yr.times(), location, dt)) {
          yield false;
        }
        if (yr.interval() > 1) {
          int anchorYear =
              data.anchor() != null
                  ? LocalDate.parse(data.anchor()).getYear()
                  : EPOCH_DATE.getYear();
          long yearOffset = date.getYear() - anchorYear;
          if (yearOffset < 0 || yearOffset % yr.interval() != 0) {
            yield false;
          }
        }
        yield matchesYearTarget(date, yr.target());
      }
    };
  }

  /** Checks if a time matches any of the scheduled times, accounting for DST gaps. */
  private static boolean timeMatchesWithDst(
      LocalDate date, List<TimeOfDay> times, ZoneId location, ZonedDateTime dt) {
    for (TimeOfDay tod : times) {
      // Direct wall-clock match
      if (dt.withZoneSameInstant(location).getHour() == tod.hour()
          && dt.withZoneSameInstant(location).getMinute() == tod.minute()) {
        return true;
      }
      // DST gap check: resolve the scheduled time and compare instants
      ZonedDateTime resolved = atTimeOnDate(date, tod, location);
      if (resolved.toInstant().equals(dt.toInstant())) {
        return true;
      }
    }
    return false;
  }

  /** Checks if a date matches a month target. */
  private static boolean matchesMonthTarget(LocalDate date, MonthTarget target) {
    return switch (target.kind()) {
      case DAYS -> target.expandDays().contains(date.getDayOfMonth());
      case LAST_DAY -> date.equals(lastDayOfMonth(date.getYear(), date.getMonth()));
      case LAST_WEEKDAY -> date.equals(lastWeekdayOfMonth(date.getYear(), date.getMonth()));
      case NEAREST_WEEKDAY -> {
        Optional<LocalDate> nwd =
            nearestWeekday(
                date.getYear(),
                date.getMonth(),
                target.nearestWeekdayDay(),
                target.nearestDirection());
        yield nwd.isPresent() && date.equals(nwd.get());
      }
      case ORDINAL_WEEKDAY -> {
        Optional<LocalDate> ord =
            nthWeekdayOfMonth(date.getYear(), date.getMonth(), target.weekday(), target.ordinal());
        yield ord.isPresent() && date.equals(ord.get());
      }
    };
  }

  /** Checks if a date matches a year target. */
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
    // Get anchor date for starting bound
    LocalDate anchorDate = data.anchor() != null ? LocalDate.parse(data.anchor()) : null;

    // Handle until clause - if now is after until, search from end of until date
    ZonedDateTime searchFrom = now;
    if (data.until() != null) {
      LocalDate untilDate = resolveUntil(data.until(), now.toLocalDate());
      // If now is after the until date, search from end of until date
      if (now.toLocalDate().isAfter(untilDate)) {
        searchFrom = ZonedDateTime.of(untilDate.plusDays(1), LocalTime.MIDNIGHT, location);
      }
    }

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      Optional<ZonedDateTime> candidate =
          prevCandidate(data.expr(), searchFrom, location, data.anchor(), data.during());
      if (candidate.isEmpty()) {
        return Optional.empty();
      }

      ZonedDateTime t = candidate.get();

      // Check if before anchor
      if (anchorDate != null && t.toLocalDate().isBefore(anchorDate)) {
        return Optional.empty();
      }

      // Check until date - should not return occurrences after until
      if (data.until() != null) {
        LocalDate untilDate = resolveUntil(data.until(), now.toLocalDate());
        if (t.toLocalDate().isAfter(untilDate)) {
          searchFrom = t;
          continue;
        }
      }

      // Check exception list
      if (isExcepted(t.toLocalDate(), data.except())) {
        searchFrom = t;
        continue;
      }

      // Check during clause
      if (!matchesDuring(t.toLocalDate(), data.during())) {
        // Skip to previous month that matches
        LocalDate prevMonth = prevDuringMonth(t.toLocalDate(), data.during());
        if (prevMonth == null) {
          return Optional.empty();
        }
        searchFrom =
            ZonedDateTime.of(
                prevMonth.plusMonths(1).withDayOfMonth(1), LocalTime.MIDNIGHT, location);
        continue;
      }

      return Optional.of(t);
    }

    return Optional.empty();
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
      case SingleDate sd -> nextSingleDate(sd, now, location);
      case YearRepeat yr -> nextYearRepeat(yr, now, location, anchor);
    };
  }

  private static Optional<ZonedDateTime> prevCandidate(
      ScheduleExpr expr,
      ZonedDateTime now,
      ZoneId location,
      String anchor,
      List<MonthName> during) {
    return switch (expr) {
      case DayRepeat dr -> prevDayRepeat(dr, now, location, anchor);
      case IntervalRepeat ir -> prevIntervalRepeat(ir, now, location);
      case WeekRepeat wr -> prevWeekRepeat(wr, now, location, anchor);
      case MonthRepeat mr -> prevMonthRepeat(mr, now, location, anchor);
      case SingleDate sd -> prevSingleDate(sd, now, location);
      case YearRepeat yr -> prevYearRepeat(yr, now, location, anchor);
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

  // Previous occurrence methods

  private static Optional<ZonedDateTime> prevDayRepeat(
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
          // Go back to previous aligned day
          day = day.minusDays(mod);
          continue;
        }
      }

      if (matchesDayFilter(day, dr.days())) {
        Optional<ZonedDateTime> time = latestPastTime(day, dr.times(), location, now);
        if (time.isPresent()) {
          return time;
        }
      }

      day = day.minusDays(dr.interval() > 1 ? dr.interval() : 1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> prevIntervalRepeat(
      IntervalRepeat ir, ZonedDateTime now, ZoneId location) {
    LocalDate day = now.toLocalDate();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      if (ir.dayFilter() != null && !matchesDayFilter(day, ir.dayFilter())) {
        day = day.minusDays(1);
        continue;
      }

      int fromMinutes = ir.fromTime().totalMinutes();
      int toMinutes = ir.toTime().totalMinutes();
      int step = ir.interval() * (ir.unit() == IntervalUnit.MINUTES ? 1 : 60);

      // Build list of times in window
      List<Integer> windowTimes = new ArrayList<>();
      for (int m = fromMinutes; m <= toMinutes; m += step) {
        windowTimes.add(m);
      }

      // Search backwards through window
      int nowMinutes =
          now.toLocalDate().equals(day) ? now.getHour() * 60 + now.getMinute() : Integer.MAX_VALUE;

      for (int j = windowTimes.size() - 1; j >= 0; j--) {
        int m = windowTimes.get(j);
        int hour = m / 60;
        int minute = m % 60;
        ZonedDateTime t = atTimeOnDate(day, new TimeOfDay(hour, minute), location);

        if (t.isBefore(now)) {
          return Optional.of(t);
        }
      }

      day = day.minusDays(1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> prevWeekRepeat(
      WeekRepeat wr, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_MONDAY;
    LocalDate anchorMonday = anchorDate.minusDays(anchorDate.getDayOfWeek().getValue() - 1);

    LocalDate day = now.toLocalDate();
    LocalDate currentMonday = day.minusDays(day.getDayOfWeek().getValue() - 1);

    // Sort target weekdays in descending order for backwards search
    List<Weekday> sortedDays = new ArrayList<>(wr.weekDays());
    sortedDays.sort((a, b) -> Integer.compare(b.number(), a.number()));

    for (int i = 0; i < 54; i++) {
      long daysBetween = ChronoUnit.DAYS.between(anchorMonday, currentMonday);
      long weeks = daysBetween / 7;

      // Skip weeks before anchor
      if (weeks < 0) {
        return Optional.empty();
      }

      if (weeks % wr.interval() == 0) {
        // Aligned week — try each target weekday in reverse order
        for (Weekday wd : sortedDays) {
          int dayOffset = wd.number() - 1;
          LocalDate targetDate = currentMonday.plusDays(dayOffset);
          Optional<ZonedDateTime> time = latestPastTime(targetDate, wr.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
      }

      // Go back to previous aligned week
      long remainder = weeks % wr.interval();
      long skipWeeks = remainder == 0 ? wr.interval() : remainder;
      currentMonday = currentMonday.minusWeeks(skipWeeks);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> prevMonthRepeat(
      MonthRepeat mr, ZonedDateTime now, ZoneId location, String anchor) {
    LocalDate anchorDate = anchor != null ? LocalDate.parse(anchor) : EPOCH_DATE;
    LocalDate day = now.toLocalDate();

    for (int i = 0; i < MAX_ITERATIONS; i++) {
      // Check month alignment
      if (mr.interval() > 1) {
        long monthsFromAnchor =
            ChronoUnit.MONTHS.between(anchorDate.withDayOfMonth(1), day.withDayOfMonth(1));
        long mod = monthsFromAnchor % mr.interval();
        if (mod < 0) mod += mr.interval();
        if (mod != 0) {
          // Go back to previous aligned month
          day = day.withDayOfMonth(1).minusMonths(mod);
          continue;
        }
      }

      // Get target days for this month
      List<LocalDate> targetDays = getTargetDaysInMonth(day.getYear(), day.getMonth(), mr.target());

      // Sort in reverse order for backwards search
      targetDays = new ArrayList<>(targetDays);
      targetDays.sort((a, b) -> b.compareTo(a));

      for (LocalDate targetDay : targetDays) {
        if (targetDay.isAfter(day)) continue;
        Optional<ZonedDateTime> time = latestPastTime(targetDay, mr.times(), location, now);
        if (time.isPresent()) {
          return time;
        }
      }

      // Move to previous month
      day = day.withDayOfMonth(1).minusMonths(mr.interval() > 1 ? mr.interval() : 1);
      // Set to last day of that month
      day = day.plusMonths(1).minusDays(1);
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> prevSingleDate(
      SingleDate sd, ZonedDateTime now, ZoneId location) {
    int startYear = now.getYear();

    switch (sd.dateSpec().kind()) {
      case ISO -> {
        LocalDate d = LocalDate.parse(sd.dateSpec().date());
        return latestPastTime(d, sd.times(), location, now);
      }
      case NAMED -> {
        for (int y = 0; y < 8; y++) {
          int year = startYear - y;
          LocalDate d = tryCreateDate(year, sd.dateSpec().month().number(), sd.dateSpec().day());
          if (d == null) {
            continue;
          }
          Optional<ZonedDateTime> time = latestPastTime(d, sd.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
        return Optional.empty();
      }
    }

    return Optional.empty();
  }

  private static Optional<ZonedDateTime> prevYearRepeat(
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
          year -= mod;
          continue;
        }
      }

      Optional<LocalDate> targetDay = getYearTargetDay(year, yr.target());

      if (targetDay.isPresent()) {
        LocalDate day = targetDay.get();
        if (!day.isAfter(now.toLocalDate())) {
          Optional<ZonedDateTime> time = latestPastTime(day, yr.times(), location, now);
          if (time.isPresent()) {
            return time;
          }
        }
      }

      year -= yr.interval() > 1 ? yr.interval() : 1;
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

  private static Optional<ZonedDateTime> latestPastTime(
      LocalDate day, List<TimeOfDay> times, ZoneId location, ZonedDateTime now) {
    ZonedDateTime best = null;
    for (TimeOfDay tod : times) {
      ZonedDateTime candidate = atTimeOnDate(day, tod, location);
      if (candidate.isBefore(now)) {
        if (best == null || candidate.isAfter(best)) {
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
      case ORDINAL_WEEKDAY -> {
        Optional<LocalDate> result =
            nthWeekdayOfMonth(year, month, target.weekday(), target.ordinal());
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

  private static LocalDate prevDuringMonth(LocalDate d, List<MonthName> during) {
    int currentMonth = d.getMonthValue();

    // Sort months in descending order
    List<Integer> months = during.stream().map(MonthName::number).sorted((a, b) -> b - a).toList();

    // Find previous month before current
    for (int m : months) {
      if (m < currentMonth) {
        // Return last day of that month
        LocalDate firstOfMonth = LocalDate.of(d.getYear(), m, 1);
        return firstOfMonth.plusMonths(1).minusDays(1);
      }
    }

    // Wrap to last month of previous year
    if (!months.isEmpty()) {
      LocalDate firstOfMonth = LocalDate.of(d.getYear() - 1, months.getFirst(), 1);
      return firstOfMonth.plusMonths(1).minusDays(1);
    }

    return null;
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
