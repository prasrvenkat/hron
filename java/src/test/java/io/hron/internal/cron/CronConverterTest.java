package io.hron.internal.cron;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import io.hron.ErrorKind;
import io.hron.HronException;
import io.hron.Schedule;
import java.time.DayOfWeek;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneOffset;
import java.time.ZonedDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.TreeSet;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.function.ThrowingSupplier;

class CronConverterTest {
  // Two years around 2044-02-29, a leap day in a February with five Mondays.
  private static final LocalDate WINDOW_START = LocalDate.of(2043, 6, 1);
  private static final LocalDate WINDOW_END = LocalDate.of(2045, 6, 1);
  // Comparing more occurrences than this one by one would slow the suite.
  private static final int FULL_COMPARE_LIMIT = 20_000;

  private static final String BOTH_DAYS =
      "not expressible in hron: cron fires on either the day of month or the day of week";
  private static final String INTERVAL_DAYS =
      "not expressible in hron: an interval runs only on every day, weekdays, the weekend or"
          + " listed days";

  private static String cronMessage(ThrowingSupplier<?> conversion) {
    HronException e = assertThrows(HronException.class, conversion::get);
    assertEquals(ErrorKind.CRON, e.kind(), e.getMessage());
    return e.getMessage();
  }

  private static String fromCronError(String cron) {
    return cronMessage(() -> Schedule.fromCron(cron));
  }

  private static String fromCron(String cron) throws HronException {
    return Schedule.fromCron(cron).toString();
  }

  /** A cron matcher written from the cron rules alone, sharing no code with the converter. */
  private record NaiveCron(
      boolean[] minutes, boolean[] hours, boolean[] months, NaiveDom dom, NaiveDow dow) {

    sealed interface NaiveDom {
      record Any() implements NaiveDom {}

      record Days(boolean[] set) implements NaiveDom {}

      record Last() implements NaiveDom {}

      record LastWeekday() implements NaiveDom {}

      record Nearest(long day) implements NaiveDom {}
    }

    sealed interface NaiveDow {
      record Any() implements NaiveDow {}

      record Days(boolean[] set) implements NaiveDow {}

      record Nth(long day, long n) implements NaiveDow {}

      record Last(long day) implements NaiveDow {}
    }

    static final String[] MONTH_NAMES = {
      "", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    };
    static final String[] DAY_NAMES = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};
    static final String[] NO_NAMES = {};

    // Expects valid syntax.
    static NaiveCron of(String input) {
      String cron =
          switch (input.trim().toLowerCase()) {
            case "@yearly", "@annually" -> "0 0 1 1 *";
            case "@monthly" -> "0 0 1 * *";
            case "@weekly" -> "0 0 * * 0";
            case "@daily", "@midnight" -> "0 0 * * *";
            case "@hourly" -> "0 * * * *";
            case String other -> other;
          };
      String[] f = cron.split("\\s+");
      assertEquals(5, f.length, "naive matcher given " + cron);
      NaiveDom dom;
      if (f[2].equals("*") || f[2].equals("?")) {
        dom = new NaiveDom.Any();
      } else if (f[2].equals("l")) {
        dom = new NaiveDom.Last();
      } else if (f[2].equals("lw")) {
        dom = new NaiveDom.LastWeekday();
      } else if (f[2].endsWith("w")) {
        dom = new NaiveDom.Nearest(number(f[2].substring(0, f[2].length() - 1), NO_NAMES));
      } else {
        dom = new NaiveDom.Days(set(f[2], 1, 31, 31, NO_NAMES));
      }
      NaiveDow dow;
      if (f[4].equals("*") || f[4].equals("?")) {
        dow = new NaiveDow.Any();
      } else if (f[4].contains("#")) {
        String[] parts = f[4].split("#");
        dow = new NaiveDow.Nth(number(parts[0], DAY_NAMES) % 7, number(parts[1], NO_NAMES));
      } else if (f[4].endsWith("l")) {
        dow = new NaiveDow.Last(number(f[4].substring(0, f[4].length() - 1), DAY_NAMES) % 7);
      } else {
        boolean[] days = set(f[4], 0, 7, 6, DAY_NAMES);
        days[0] |= days[7];
        dow = new NaiveDow.Days(Arrays.copyOf(days, 7));
      }
      return new NaiveCron(
          set(f[0], 0, 59, 59, NO_NAMES),
          set(f[1], 0, 23, 23, NO_NAMES),
          set(f[3], 1, 12, 12, MONTH_NAMES),
          dom,
          dow);
    }

    static long number(String text, String[] names) {
      for (int i = 0; i < names.length; i++) {
        if (names[i].equals(text)) {
          return i;
        }
      }
      try {
        return Long.parseLong(text);
      } catch (NumberFormatException e) {
        return Long.MAX_VALUE;
      }
    }

    static boolean[] set(String field, long min, long max, long starMax, String[] names) {
      boolean[] set = new boolean[(int) max + 1];
      for (String item : field.split(",")) {
        int slash = item.indexOf('/');
        String range = slash >= 0 ? item.substring(0, slash) : item;
        Long step = slash >= 0 ? number(item.substring(slash + 1), NO_NAMES) : null;
        long low;
        long high;
        if (range.equals("*")) {
          low = min;
          high = starMax;
        } else if (range.contains("-")) {
          String[] bounds = range.split("-");
          low = number(bounds[0], names);
          high = number(bounds[1], names);
        } else {
          low = number(range, names);
          high = step != null ? Math.max(low, starMax) : low;
        }
        long by = step == null ? 1 : step;
        for (long value = low; value <= high; ) {
          set[(int) value] = true;
          value = by > Long.MAX_VALUE - value ? Long.MAX_VALUE : value + by;
        }
      }
      return set;
    }

    List<LocalTime> times() {
      List<LocalTime> times = new ArrayList<>();
      for (int hour = 0; hour < 24; hour++) {
        for (int minute = 0; minute < 60; minute++) {
          if (hours[hour] && minutes[minute]) {
            times.add(LocalTime.of(hour, minute));
          }
        }
      }
      return times;
    }

    boolean firesOn(LocalDate d) {
      int day = d.getDayOfMonth();
      int last = d.lengthOfMonth();
      long weekday = d.getDayOfWeek().getValue() % 7;
      List<Integer> weekdays = new ArrayList<>();
      for (int n = 1; n <= last; n++) {
        DayOfWeek w = d.withDayOfMonth(n).getDayOfWeek();
        if (w != DayOfWeek.SATURDAY && w != DayOfWeek.SUNDAY) {
          weekdays.add(n);
        }
      }
      Boolean domMatch =
          switch (dom) {
            case NaiveDom.Any _ -> null;
            case NaiveDom.Days(boolean[] set) -> set[day];
            case NaiveDom.Last _ -> day == last;
            case NaiveDom.LastWeekday _ -> day == weekdays.getLast();
            case NaiveDom.Nearest(long n) -> {
              int nearest = weekdays.getFirst();
              for (int w : weekdays) {
                if (Math.abs(w - n) < Math.abs(nearest - n)) {
                  nearest = w;
                }
              }
              yield n <= last && day == nearest;
            }
          };
      Boolean dowMatch =
          switch (dow) {
            case NaiveDow.Any _ -> null;
            case NaiveDow.Days(boolean[] set) -> set[(int) weekday];
            case NaiveDow.Nth(long dd, long n) -> weekday == dd && (day - 1) / 7 + 1 == n;
            case NaiveDow.Last(long dd) -> weekday == dd && day + 7 > last;
          };
      boolean dayMatches;
      if (domMatch == null && dowMatch == null) {
        dayMatches = true;
      } else if (domMatch == null || dowMatch == null) {
        dayMatches = Objects.requireNonNullElse(domMatch, dowMatch);
      } else {
        dayMatches = domMatch || dowMatch;
      }
      return months[d.getMonthValue()] && dayMatches;
    }

    boolean bothDaysRestricted() {
      return !(dom instanceof NaiveDom.Any) && !(dow instanceof NaiveDow.Any);
    }

    boolean daysCarryAnInterval() {
      if (dom instanceof NaiveDom.Any) {
        return dow instanceof NaiveDow.Any || dow instanceof NaiveDow.Days;
      }
      if (dom instanceof NaiveDom.Days(boolean[] days) && dow instanceof NaiveDow.Any) {
        for (int d = 1; d <= 31; d++) {
          if (!days[d]) {
            return false;
          }
        }
        return true;
      }
      return false;
    }
  }

  private static List<LocalDate> windowDays() {
    return WINDOW_START.datesUntil(WINDOW_END).toList();
  }

  private static ZonedDateTime utc(LocalDate d, int hour, int minute) {
    return ZonedDateTime.of(d, LocalTime.of(hour, minute), ZoneOffset.UTC);
  }

  private static Optional<LocalDateTime> wall(Optional<ZonedDateTime> z) {
    return z.map(ZonedDateTime::toLocalDateTime);
  }

  private static void assertFiresAs(Schedule schedule, NaiveCron cron, String label) {
    List<LocalTime> times = cron.times();
    List<LocalDate> days = windowDays().stream().filter(cron::firesOn).toList();
    if ((long) days.size() * times.size() <= FULL_COMPARE_LIMIT) {
      assertEachOccurrence(schedule, days, times, WINDOW_END, label);
      return;
    }
    LocalDate earlyEnd = days.get(1).plusDays(1);
    assertEachOccurrence(schedule, days.subList(0, 2), times, earlyEnd, label);
    // Too many to compare one by one. In UTC an hron schedule fires at the same times on every day
    // it fires, so the two days compared in full stand for the times of the rest; on each day the
    // first and the last time, searched from the day before, show that it fires that day and on no
    // day between.
    ZonedDateTime cursor = utc(WINDOW_START, 0, 0).minusSeconds(1);
    for (LocalDate d : days) {
      assertEquals(
          Optional.of(d.atTime(times.getFirst())),
          wall(schedule.nextFrom(cursor)),
          label + ": first time on " + d);
      ZonedDateTime endOfDay = utc(d.plusDays(1), 0, 0);
      assertEquals(
          Optional.of(d.atTime(times.getLast())),
          wall(schedule.previousFrom(endOfDay)),
          label + ": last time on " + d);
      cursor = endOfDay.minusSeconds(1);
    }
    Optional<LocalDate> after = schedule.nextFrom(cursor).map(ZonedDateTime::toLocalDate);
    assertTrue(
        after.isEmpty() || !after.get().isBefore(WINDOW_END),
        label + ": fires on " + after + ", after the last day the cron fires");
  }

  private static void assertEachOccurrence(
      Schedule schedule, List<LocalDate> days, List<LocalTime> times, LocalDate end, String label) {
    ZonedDateTime from = utc(WINDOW_START, 0, 0).minusSeconds(1);
    ZonedDateTime to = utc(end, 0, 0).minusSeconds(1);
    Iterator<LocalDateTime> actual =
        schedule.between(from, to).map(ZonedDateTime::toLocalDateTime).iterator();
    for (LocalDate d : days) {
      for (LocalTime t : times) {
        LocalDateTime expected = d.atTime(t);
        LocalDateTime got = actual.hasNext() ? actual.next() : null;
        if (!expected.equals(got)) {
          fail(label + ": expected " + expected + ", got " + got);
        }
      }
    }
    if (actual.hasNext()) {
      fail(label + ": expected no more, got " + actual.next());
    }
  }

  private static boolean hasEqualGaps(List<LocalTime> times) {
    if (times.size() < 3) {
      return false;
    }
    int gap = minuteOfDay(times.get(1)) - minuteOfDay(times.get(0));
    for (int i = 1; i < times.size(); i++) {
      if (minuteOfDay(times.get(i)) - minuteOfDay(times.get(i - 1)) != gap) {
        return false;
      }
    }
    return true;
  }

  private static int minuteOfDay(LocalTime t) {
    return t.getHour() * 60 + t.getMinute();
  }

  private static String tooManyMessage(List<LocalTime> times) {
    return hasEqualGaps(times)
        ? INTERVAL_DAYS
        : "not expressible in hron: " + times.size() + " times a day are too many to list";
  }

  /** xorshift64*, so the generated cases are the same on every run. */
  private static final class Rng {
    private long state;

    Rng(long seed) {
      state = seed;
    }

    String pick(String[] items) {
      return items[pickIndex(items.length)];
    }

    int pickIndex(int length) {
      state ^= state >>> 12;
      state ^= state << 25;
      state ^= state >>> 27;
      long n = (state * 0x2545_f491_4f6c_dd1dL) >>> 32;
      return (int) (n % length);
    }
  }

  private static final String[] MINUTE_FIELDS = {
    "0",
    "30",
    "*/15",
    "0-30/10",
    "5,35",
    "*",
    "59",
    "*/7",
    "00",
    "10-50/20",
    "45/5",
    "0/20",
    "1-3",
    "*/99999999999999999999",
    "0,15,30,45",
    "5-10/5",
    "0-59/30",
    "*/20",
  };
  private static final String[] HOUR_FIELDS = {
    "9",
    "*",
    "*/2",
    "9-17",
    "9-17/2",
    "0,12",
    "23",
    "0-20/4",
    "*/5",
    "22,0,2",
    "1-23",
    "7/30",
    "009",
    "0-11",
    "*/1",
    "12-12/250",
    "0-16/4",
    "1-21/4",
  };
  private static final String[] DOM_FIELDS = {
    "*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29", "30", "lw", "1W", "31W",
    "*/2", "1-31", "5-20/3", "15,1", "02", "l", "28-31", "30W", "29w", "1-30", "2-31",
  };
  private static final String[] MONTH_FIELDS = {
    "*",
    "1",
    "JAN",
    "1-3",
    "*/3",
    "2",
    "dec",
    "4",
    "feb",
    "1,7",
    "jun-aug",
    "12,1",
    "*/12",
    "2/5",
    "12-12/250",
    "Sep",
    "2",
    "2",
  };
  private static final String[] DOW_FIELDS = {
    "*",
    "1-5",
    "MON",
    "0",
    "7",
    "5L",
    "1#2",
    "SUN#1",
    "?",
    "1-5/2",
    "sat,sun",
    "0-7",
    "7/2",
    "5-7",
    "fri#5",
    "1#5",
    "0l",
    "mon-fri/2",
    "6,7",
    "7,1",
    "0-6",
    "5/1",
    "*/3",
    "tue-thu",
    "1,1,3",
    "1-4",
    "mon-thu",
    "1-6",
    "0-5",
    "0,6,1",
    "sun,sat",
  };
  private static final String[] ANY_DAY = {"*"};

  // Two crons in three keep one day field `*`, so most convert; the third draws both, so some are
  // rejected for restricting both.
  private static List<String> generatedCrons(long shard) {
    Rng rng = new Rng(0x9e37_79b9_7f4a_7c15L ^ shard);
    List<String> crons = new ArrayList<>();
    for (int i = 0; i < 150; i++) {
      String[] dom = i % 3 == 1 ? ANY_DAY : DOM_FIELDS;
      String[] dow = i % 3 == 0 ? ANY_DAY : DOW_FIELDS;
      List<String> fields = new ArrayList<>();
      for (String[] field : List.of(MINUTE_FIELDS, HOUR_FIELDS, dom, MONTH_FIELDS, dow)) {
        fields.add(rng.pick(field));
      }
      crons.add(String.join(" ", fields));
    }
    return crons;
  }

  private static void checkFromCron(long shard) throws HronException {
    int accepted = 0;
    for (String cron : generatedCrons(shard)) {
      NaiveCron naive = NaiveCron.of(cron);
      List<LocalTime> times = naive.times();
      if (naive.bothDaysRestricted()) {
        assertEquals(BOTH_DAYS, fromCronError(cron), cron);
        continue;
      }
      boolean interval = naive.daysCarryAnInterval() && hasEqualGaps(times);
      if (times.size() > 24 && !interval) {
        assertEquals(tooManyMessage(times), fromCronError(cron), cron);
        continue;
      }
      Schedule schedule = Schedule.fromCron(cron);
      assertFiresAs(schedule, naive, cron);

      String back = schedule.toCron();
      Schedule again = Schedule.fromCron(back);
      String label = cron + " -> " + schedule + " -> " + back;
      if (!again.data().equals(schedule.data())) {
        assertFiresAs(again, naive, label);
      }
      NaiveCron naiveBack = NaiveCron.of(back);
      assertEquals(times, naiveBack.times(), label);
      for (LocalDate d : windowDays()) {
        assertEquals(naive.firesOn(d), naiveBack.firesOn(d), label + " on " + d);
      }
      accepted++;
    }
    assertTrue(accepted >= 60, "only " + accepted + " generated crons were accepted");
  }

  @Test
  void fromCronIsExactShard0() throws HronException {
    checkFromCron(0);
  }

  @Test
  void fromCronIsExactShard1() throws HronException {
    checkFromCron(1);
  }

  @Test
  void fromCronIsExactShard2() throws HronException {
    checkFromCron(2);
  }

  @Test
  void fromCronIsExactShard3() throws HronException {
    checkFromCron(3);
  }

  private static final String[] TIME_LISTS = {
    "09:00",
    "00:00",
    "23:59",
    "09:00, 17:00",
    "17:00, 09:00, 09:00",
    "00:00, 12:00",
    "09:00, 13:00, 17:00",
    "09:00, 17:30",
    "00:05, 00:35",
    "00:00, 00:01, 00:02, 00:30",
    "00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00,"
        + " 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00,"
        + " 12:10",
    "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00,"
        + " 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59",
    "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00,"
        + " 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00",
    "09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00,"
        + " 15:30",
    "09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12,"
        + " 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24",
  };

  /** {@code ownMonth} is the month the expression names, which a {@code during} must include. */
  private record DayExpression(String hron, String ownMonth) {}

  private static final DayExpression[] DAY_EXPRESSIONS = {
    new DayExpression("every day", null),
    new DayExpression("every weekday", null),
    new DayExpression("every weekend", null),
    new DayExpression("every monday", null),
    new DayExpression("every sunday, saturday", null),
    new DayExpression("every friday, saturday, sunday", null),
    new DayExpression("every week on tuesday, friday", null),
    new DayExpression("every 1 day", null),
    new DayExpression("every month on the 1st", null),
    new DayExpression("every month on the 1st to 5th, 20th", null),
    new DayExpression("every month on the 31st", null),
    new DayExpression("every month on the 15th, 1st", null),
    new DayExpression("every month on the 1st to 31st", null),
    new DayExpression("every month on the last day", null),
    new DayExpression("every month on the last weekday", null),
    new DayExpression("every month on the nearest weekday to 1st", null),
    new DayExpression("every month on the nearest weekday to 31st", null),
    new DayExpression("every month on the nearest weekday to 15th", null),
    new DayExpression("every month on the first monday", null),
    new DayExpression("every month on the fifth friday", null),
    new DayExpression("every month on the last sunday", null),
    new DayExpression("every year on feb 29", "feb"),
    new DayExpression("every year on dec 25", "dec"),
    new DayExpression("every year on the 15th of march", "mar"),
    new DayExpression("every year on the first monday of mar", "mar"),
    new DayExpression("every year on the fifth monday of feb", "feb"),
    new DayExpression("every year on the last friday of feb", "feb"),
    new DayExpression("every year on the last weekday of dec", "dec"),
    new DayExpression("on feb 14", "feb"),
    new DayExpression("on feb 29", "feb"),
  };
  private static final String[] INTERVALS = {
    "every 30 min from 09:00 to 17:30",
    "every 15 min from 00:00 to 23:59",
    "every 2 hours from 00:00 to 23:59",
    "every 7 hours from 00:00 to 23:59",
    "every 45 min from 09:00 to 17:00",
    "every 20 min from 09:00 to 17:40",
    "every 1 minute from 00:00 to 23:59",
    "every 120 min from 01:00 to 23:00",
    "every 2147483647 hours from 00:00 to 23:59",
    "every 5 min from 10:00 to 10:30",
    "every 4 hours from 00:00 to 20:00",
    "every 1 hour from 09:05 to 17:05",
    "every 30 min from 09:00 to 17:00",
  };
  private static final String[] INTERVAL_DAYS_FILTERS = {
    "", " on weekday", " on weekend", " on monday, friday"
  };
  private static final String[] DURING = {
    "",
    "",
    " during feb",
    " during dec",
    " during jan, jul",
    " during dec, jan, feb",
    " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
  };

  private record GeneratedSchedule(String hron, List<Long> times, String ownMonth, String during) {}

  private static List<GeneratedSchedule> generatedSchedules() {
    Rng rng = new Rng(0x2545_f491_4f6c_dd1dL);
    List<GeneratedSchedule> schedules = new ArrayList<>();
    for (int i = 0; i < 240; i++) {
      String during = rng.pick(DURING);
      if (i % 3 == 0) {
        String filter = rng.pick(INTERVAL_DAYS_FILTERS);
        String interval = rng.pick(INTERVALS);
        schedules.add(
            new GeneratedSchedule(
                interval + filter + during, naiveIntervalTimes(interval), null, during));
      } else {
        DayExpression days = DAY_EXPRESSIONS[rng.pickIndex(DAY_EXPRESSIONS.length)];
        String times = rng.pick(TIME_LISTS);
        List<Long> minutes = new ArrayList<>();
        for (String time : times.split(", ")) {
          minutes.add(naiveMinuteOfDay(time));
        }
        schedules.add(
            new GeneratedSchedule(
                days.hron() + " at " + times + during, minutes, days.ownMonth(), during));
      }
    }
    return schedules;
  }

  private static long naiveMinuteOfDay(String time) {
    String[] parts = time.split(":");
    return Long.parseLong(parts[0]) * 60 + Long.parseLong(parts[1]);
  }

  private static List<Long> naiveIntervalTimes(String interval) {
    String[] words = interval.split(" ");
    long every = Long.parseLong(words[1]);
    long step = words[2].startsWith("hour") ? every * 60 : every;
    long from = naiveMinuteOfDay(words[4]);
    long to = naiveMinuteOfDay(words[6]);
    List<Long> times = new ArrayList<>();
    for (long t = from; t <= to; t++) {
      if ((t - from) % step == 0) {
        times.add(t);
      }
    }
    return times;
  }

  /** The reason toCron must give, decided from the generated parts alone. */
  private static String expectedToCronFailure(GeneratedSchedule generated) {
    if (generated.ownMonth() != null
        && !generated.during().isEmpty()
        && !generated.during().contains(generated.ownMonth())) {
      return "during excludes the schedule's month";
    }
    TreeSet<Long> times = new TreeSet<>(generated.times());
    TreeSet<Long> minutes = new TreeSet<>();
    TreeSet<Long> hours = new TreeSet<>();
    for (long t : times) {
      minutes.add(t % 60);
      hours.add(t / 60);
    }
    return minutes.size() * hours.size() != times.size()
        ? "times are not every combination of their minutes and hours"
        : null;
  }

  @Test
  void toCronIsExact() throws HronException {
    int accepted = 0;
    int rejected = 0;
    for (GeneratedSchedule generated : generatedSchedules()) {
      String hron = generated.hron();
      Schedule schedule = Schedule.parse(hron);
      String reason = expectedToCronFailure(generated);
      if (reason != null) {
        assertEquals("not expressible as cron: " + reason, cronMessage(schedule::toCron), hron);
        rejected++;
        continue;
      }
      String cron = schedule.toCron();
      NaiveCron naive = NaiveCron.of(cron);
      assertFiresAs(schedule, naive, hron + " -> " + cron);
      accepted++;

      List<LocalTime> times = naive.times();
      String label = hron + " -> " + cron + " -> fromCron";
      boolean interval = naive.daysCarryAnInterval() && hasEqualGaps(times);
      if (times.size() > 24 && !interval) {
        assertEquals(tooManyMessage(times), fromCronError(cron), label);
        continue;
      }
      assertFiresAs(Schedule.fromCron(cron), naive, label);
    }
    assertTrue(
        accepted >= 60 && rejected >= 20,
        "only " + accepted + " generated schedules converted and " + rejected + " were rejected");
  }

  @Test
  void valuesOfAnyLengthNeverOverflow() throws HronException {
    String longZeros = "0".repeat(10_000);
    assertEquals("every day at 09:09", fromCron(longZeros + "9 " + longZeros + "9 * * *"));
    String huge = "9".repeat(10_000);
    assertEquals(
        "day of week ordinal must be 1-5, got " + huge, fromCronError("0 9 * * 1#" + huge));
    assertEquals("day of month must be 1-31, got " + huge, fromCronError("0 9 " + huge + "W * *"));
    assertEquals("hour must be 0-23, got " + huge, fromCronError("0 " + huge + "-1 * * *"));
    assertEquals("every monday at 09:00", fromCron("0 9 * * 1-5/" + huge));
    assertEquals("day of week step must be at least 1", fromCronError("0 9 * * */" + longZeros));
    assertEquals("every sunday at 09:00", fromCron("0 9 * * 0-7/" + longZeros + "7"));
  }

  @Test
  void aLongFieldIsParsedInLinearTime() throws HronException {
    String items = String.join(",", Collections.nCopies(200_000, "1"));
    assertEquals("every month on the 1st at 09:00", fromCron("0 9 " + items + " * *"));
    String ranges = String.join(",", Collections.nCopies(50_000, "0-59/1"));
    assertEquals("every 1 minute from 09:00 to 09:59", fromCron(ranges + " 9 * * *"));
  }

  @Test
  void sevenMinuteStepsConvertOnlyWithinOneHour() throws HronException {
    assertEquals("every 7 min from 09:00 to 09:56", fromCron("*/7 9 * * *"));
    assertEquals(
        "not expressible in hron: 216 times a day are too many to list",
        fromCronError("*/7 * * * *"));
  }

  @Test
  void naiveMatcherAgreesWithKnownDates() {
    assertTrue(NaiveCron.of("0 9 * 2 1#5").firesOn(LocalDate.of(2044, 2, 29)));
    assertTrue(
        NaiveCron.of("0 9 1W * *").firesOn(LocalDate.of(2043, 8, 3)),
        "Saturday the 1st moves to Monday");
    assertTrue(NaiveCron.of("0 9 31W * *").firesOn(LocalDate.of(2043, 8, 31)), "Monday the 31st");
    assertTrue(
        NaiveCron.of("0 9 30W * *").firesOn(LocalDate.of(2044, 4, 29)),
        "Saturday the 30th moves to Friday");
    assertTrue(
        NaiveCron.of("0 9 31W * *").firesOn(LocalDate.of(2044, 7, 29)),
        "Sunday the 31st moves to Friday");
    assertFalse(
        NaiveCron.of("0 9 31W * *").firesOn(LocalDate.of(2044, 4, 30)), "April has no 31st");
    assertTrue(NaiveCron.of("0 9 LW * *").firesOn(LocalDate.of(2044, 4, 29)));
    assertTrue(NaiveCron.of("0 9 * * 5L").firesOn(LocalDate.of(2044, 4, 29)));
    assertFalse(NaiveCron.of("0 9 * * 5L").firesOn(LocalDate.of(2044, 4, 22)));
  }
}
