package io.hron.cron;

import io.hron.HronException;
import io.hron.ast.DateSpec;
import io.hron.ast.DayFilter;
import io.hron.ast.DayOfMonthSpec;
import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.IntervalUnit;
import io.hron.ast.MonthName;
import io.hron.ast.MonthRepeat;
import io.hron.ast.MonthTarget;
import io.hron.ast.OrdinalPosition;
import io.hron.ast.ScheduleData;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.TimeOfDay;
import io.hron.ast.WeekRepeat;
import io.hron.ast.Weekday;
import io.hron.ast.YearRepeat;
import io.hron.ast.YearTarget;
import io.hron.eval.Evaluator;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.OptionalInt;
import java.util.TreeSet;
import java.util.stream.Collectors;

public final class CronConverter {
  private CronConverter() {}

  private static final int MAX_LISTED_TIMES = 24;
  private static final String BOTH_DAYS_RESTRICTED =
      "not expressible in hron: cron fires on either the day of month or the day of week";
  private static final String INTERVAL_DAYS =
      "not expressible in hron: an interval runs only on every day, weekdays, the weekend or"
          + " listed days";
  private static final int MINUTES_PER_DAY = 24 * 60;
  private static final TimeOfDay MIDNIGHT = new TimeOfDay(0, 0);
  private static final TimeOfDay END_OF_DAY = new TimeOfDay(23, 59);

  // Digit strings may be of any length. Every number at or above this cap is out of every field's
  // range and steps past every range's end, so saturating at it keeps each comparison exact
  // without overflow.
  private static final int NUMBER_CAP = 1000;

  private static final String[] MONTH_NAMES = {
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
  };
  private static final String[] DAY_NAMES = {"sun", "mon", "tue", "wed", "thu", "fri", "sat"};
  private static final MonthName[] MONTHS = MonthName.values();
  private static final Weekday[] WEEKDAYS = {
    Weekday.SUNDAY,
    Weekday.MONDAY,
    Weekday.TUESDAY,
    Weekday.WEDNESDAY,
    Weekday.THURSDAY,
    Weekday.FRIDAY,
    Weekday.SATURDAY
  };
  private static final OrdinalPosition[] ORDINALS = {
    OrdinalPosition.FIRST,
    OrdinalPosition.SECOND,
    OrdinalPosition.THIRD,
    OrdinalPosition.FOURTH,
    OrdinalPosition.FIFTH
  };

  private enum Field {
    MINUTE("minute", 0, 59, new String[0]),
    HOUR("hour", 0, 23, new String[0]),
    DAY_OF_MONTH("day of month", 1, 31, new String[0]),
    MONTH("month", 1, 12, MONTH_NAMES),
    DAY_OF_WEEK("day of week", 0, 7, DAY_NAMES);

    final String label;
    final int min;
    final int max;
    final String[] names;

    Field(String label, int min, int max, String[] names) {
      this.label = label;
      this.min = min;
      this.max = max;
      this.names = names;
    }

    // In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
    int starEnd() {
      return this == DAY_OF_WEEK ? 6 : max;
    }
  }

  private sealed interface Bounds {
    record Star() implements Bounds {}

    record Value(String a) implements Bounds {}

    record Range(String a, String b) implements Bounds {}
  }

  private record Item(Bounds bounds, String step) {}

  private sealed interface MonthDays {
    record Any() implements MonthDays {}

    record Days(List<Integer> days) implements MonthDays {}

    record Last() implements MonthDays {}

    record LastWeekday() implements MonthDays {}

    record Nearest(int day) implements MonthDays {}
  }

  private sealed interface WeekDays {
    record Any() implements WeekDays {}

    record Days(List<Integer> days) implements WeekDays {}

    record Nth(Weekday weekday, int n) implements WeekDays {}

    record Last(Weekday weekday) implements WeekDays {}
  }

  private sealed interface Days {
    record OfWeek(DayFilter filter) implements Days {}

    record OfMonth(MonthTarget target) implements Days {}
  }

  private record DayFields(String dayOfMonth, String dayOfWeek) {}

  private record TimeFields(String minute, String hour) {}

  public static ScheduleData fromCron(String input) throws HronException {
    String trimmed = trimCron(input);
    String text = trimmed.startsWith("@") ? shortcut(trimmed) : trimmed;
    List<String> fields = splitFields(text);
    if (fields.size() != 5) {
      throw HronException.cron("expected 5 cron fields, got " + fields.size());
    }

    List<Integer> minutes = sorted(values(fields.get(0), Field.MINUTE));
    List<Integer> hours = sorted(values(fields.get(1), Field.HOUR));
    MonthDays monthDays = parseDayOfMonth(fields.get(2));
    List<Integer> months = sorted(values(fields.get(3), Field.MONTH));
    WeekDays weekDays = parseDayOfWeek(fields.get(4));
    Days days = dayExpression(monthDays, weekDays);
    List<TimeOfDay> times = new ArrayList<>();
    for (int hour : hours) {
      for (int minute : minutes) {
        times.add(new TimeOfDay(hour, minute));
      }
    }

    OptionalInt gap = equalGap(times);
    ScheduleExpr expr;
    if (days instanceof Days.OfWeek(DayFilter filter) && gap.isPresent()) {
      expr = interval(times, gap.getAsInt(), filter);
    } else if (times.size() > MAX_LISTED_TIMES) {
      throw tooManyTimes(times.size(), gap);
    } else if (yearTarget(days, months) instanceof YearTarget target) {
      expr = new YearRepeat(1, target, times);
    } else {
      expr =
          switch (days) {
            case Days.OfWeek(DayFilter filter) -> new DayRepeat(1, filter, times);
            case Days.OfMonth(MonthTarget target) -> new MonthRepeat(1, target, times);
          };
    }
    boolean yearly = expr instanceof YearRepeat;
    List<MonthName> during = new ArrayList<>();
    if (!yearly && months.size() < MONTHS.length) {
      for (int month : months) {
        during.add(MONTHS[month - 1]);
      }
    }
    return new ScheduleData(expr, null, List.of(), null, null, during);
  }

  private static boolean isCronSpace(char ch) {
    return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';
  }

  private static String trimCron(String input) {
    int start = 0;
    int end = input.length();
    while (start < end && isCronSpace(input.charAt(start))) {
      start++;
    }
    while (end > start && isCronSpace(input.charAt(end - 1))) {
      end--;
    }
    return input.substring(start, end);
  }

  private static List<String> splitFields(String text) {
    List<String> fields = new ArrayList<>();
    int start = 0;
    for (int i = 0; i <= text.length(); i++) {
      if (i == text.length() || text.charAt(i) == ' ' || text.charAt(i) == '\t') {
        if (i > start) {
          fields.add(text.substring(start, i));
        }
        start = i + 1;
      }
    }
    return fields;
  }

  private static String shortcut(String input) throws HronException {
    return switch (asciiLowercase(input)) {
      case "@yearly", "@annually" -> "0 0 1 1 *";
      case "@monthly" -> "0 0 1 * *";
      case "@weekly" -> "0 0 * * 0";
      case "@daily", "@midnight" -> "0 0 * * *";
      case "@hourly" -> "0 * * * *";
      default -> throw HronException.cron("unknown cron shortcut: " + input);
    };
  }

  private static MonthDays parseDayOfMonth(String text) throws HronException {
    if (text.equals("*") || text.equals("?")) {
      return new MonthDays.Any();
    }
    if (asciiEqualsIgnoreCase(text, "L")) {
      return new MonthDays.Last();
    }
    if (asciiEqualsIgnoreCase(text, "LW")) {
      return new MonthDays.LastWeekday();
    }
    if (endsWithAsciiLetter(text, 'w') && isNumber(withoutLast(text))) {
      return new MonthDays.Nearest(fieldValue(withoutLast(text), Field.DAY_OF_MONTH));
    }
    return new MonthDays.Days(values(text, Field.DAY_OF_MONTH));
  }

  private static WeekDays parseDayOfWeek(String text) throws HronException {
    Field field = Field.DAY_OF_WEEK;
    if (text.equals("*") || text.equals("?")) {
      return new WeekDays.Any();
    }
    int hash = text.indexOf('#');
    if (hash >= 0
        && isValue(text.substring(0, hash), field)
        && isNumber(text.substring(hash + 1))) {
      String day = text.substring(0, hash);
      String nth = text.substring(hash + 1);
      Weekday weekday = WEEKDAYS[fieldValue(day, field) % 7];
      int n = number(nth);
      if (n < 1 || n > 5) {
        throw HronException.cron("day of week ordinal must be 1-5, got " + nth);
      }
      return new WeekDays.Nth(weekday, n);
    }
    if (endsWithAsciiLetter(text, 'l') && isValue(withoutLast(text), field)) {
      return new WeekDays.Last(WEEKDAYS[fieldValue(withoutLast(text), field) % 7]);
    }
    return new WeekDays.Days(values(text, field));
  }

  private static boolean endsWithAsciiLetter(String text, char lower) {
    return !text.isEmpty() && asciiLowercase(text.charAt(text.length() - 1)) == lower;
  }

  private static String withoutLast(String text) {
    return text.substring(0, text.length() - 1);
  }

  // Keeps the order of first appearance, in which fromCron lists days of the week.
  private static List<Integer> values(String text, Field field) throws HronException {
    List<Item> items = items(text, field);
    if (items == null) {
      throw HronException.cron("invalid " + field.label + ": " + text);
    }
    List<Integer> values = new ArrayList<>();
    for (Item item : items) {
      int first;
      int last;
      switch (item.bounds()) {
        case Bounds.Star _ -> {
          first = field.min;
          last = field.starEnd();
        }
        case Bounds.Value(String a) -> {
          first = fieldValue(a, field);
          // `7/n` starts past the end of `*`, so it is Sunday alone.
          last = item.step() != null ? Math.max(first, field.starEnd()) : first;
        }
        case Bounds.Range(String a, String b) -> {
          first = fieldValue(a, field);
          last = fieldValue(b, field);
          if (first > last) {
            throw HronException.cron(field.label + " range must not run backwards: " + a + "-" + b);
          }
        }
      }
      int step = item.step() == null ? 1 : number(item.step());
      if (step == 0) {
        throw HronException.cron(field.label + " step must be at least 1");
      }
      for (int value = first; value <= last; value += step) {
        int kept = field == Field.DAY_OF_WEEK ? value % 7 : value;
        if (!values.contains(kept)) {
          values.add(kept);
        }
      }
    }
    return values;
  }

  private static List<Item> items(String text, Field field) {
    List<Item> items = new ArrayList<>();
    for (String item : text.split(",", -1)) {
      int slash = item.indexOf('/');
      String range = slash >= 0 ? item.substring(0, slash) : item;
      String step = slash >= 0 ? item.substring(slash + 1) : null;
      int dash = range.indexOf('-');
      Bounds bounds;
      if (range.equals("*")) {
        bounds = new Bounds.Star();
      } else if (dash >= 0) {
        bounds = new Bounds.Range(range.substring(0, dash), range.substring(dash + 1));
      } else {
        bounds = new Bounds.Value(range);
      }
      boolean valid =
          (step == null || isNumber(step))
              && switch (bounds) {
                case Bounds.Star _ -> true;
                case Bounds.Value(String a) -> isValue(a, field);
                case Bounds.Range(String a, String b) -> isValue(a, field) && isValue(b, field);
              };
      if (!valid) {
        return null;
      }
      items.add(new Item(bounds, step));
    }
    return items;
  }

  private static boolean isNumber(String text) {
    if (text.isEmpty()) {
      return false;
    }
    for (int i = 0; i < text.length(); i++) {
      char ch = text.charAt(i);
      if (ch < '0' || ch > '9') {
        return false;
      }
    }
    return true;
  }

  private static boolean isValue(String text, Field field) {
    return isNumber(text) || nameValue(text, field).isPresent();
  }

  private static OptionalInt nameValue(String text, Field field) {
    for (int index = 0; index < field.names.length; index++) {
      if (asciiEqualsIgnoreCase(field.names[index], text)) {
        return OptionalInt.of(index + field.min);
      }
    }
    return OptionalInt.empty();
  }

  private static int number(String digits) {
    int n = 0;
    for (int i = 0; i < digits.length(); i++) {
      n = Math.min(n * 10 + (digits.charAt(i) - '0'), NUMBER_CAP);
    }
    return n;
  }

  private static int fieldValue(String text, Field field) throws HronException {
    int value = nameValue(text, field).orElseGet(() -> number(text));
    if (value < field.min || value > field.max) {
      throw HronException.cron(
          field.label + " must be " + field.min + "-" + field.max + ", got " + text);
    }
    return value;
  }

  private static char asciiLowercase(char ch) {
    return ch >= 'A' && ch <= 'Z' ? (char) (ch + ('a' - 'A')) : ch;
  }

  private static String asciiLowercase(String text) {
    StringBuilder out = new StringBuilder(text.length());
    for (int i = 0; i < text.length(); i++) {
      out.append(asciiLowercase(text.charAt(i)));
    }
    return out.toString();
  }

  private static boolean asciiEqualsIgnoreCase(String a, String b) {
    if (a.length() != b.length()) {
      return false;
    }
    for (int i = 0; i < a.length(); i++) {
      if (asciiLowercase(a.charAt(i)) != asciiLowercase(b.charAt(i))) {
        return false;
      }
    }
    return true;
  }

  private static Days dayExpression(MonthDays monthDays, WeekDays weekDays) throws HronException {
    if (!(monthDays instanceof MonthDays.Any) && !(weekDays instanceof WeekDays.Any)) {
      throw HronException.cron(BOTH_DAYS_RESTRICTED);
    }
    return switch (monthDays) {
      case MonthDays.Any _ ->
          switch (weekDays) {
            case WeekDays.Any _ -> new Days.OfWeek(DayFilter.every());
            case WeekDays.Days(List<Integer> days) -> new Days.OfWeek(weekdayFilter(days));
            case WeekDays.Nth(Weekday weekday, int n) ->
                new Days.OfMonth(MonthTarget.ordinalWeekday(ORDINALS[n - 1], weekday));
            case WeekDays.Last(Weekday weekday) ->
                new Days.OfMonth(MonthTarget.ordinalWeekday(OrdinalPosition.LAST, weekday));
          };
      case MonthDays.Days(List<Integer> days) when days.size() == 31 ->
          new Days.OfWeek(DayFilter.every());
      case MonthDays.Days(List<Integer> days) -> {
        List<DayOfMonthSpec> specs = new ArrayList<>();
        for (int[] run : runs(sorted(days))) {
          specs.add(
              run[0] == run[1]
                  ? DayOfMonthSpec.single(run[0])
                  : DayOfMonthSpec.range(run[0], run[1]));
        }
        yield new Days.OfMonth(MonthTarget.days(specs));
      }
      case MonthDays.Last _ -> new Days.OfMonth(MonthTarget.lastDay());
      case MonthDays.LastWeekday _ -> new Days.OfMonth(MonthTarget.lastWeekday());
      case MonthDays.Nearest(int day) -> new Days.OfMonth(MonthTarget.nearestWeekday(day));
    };
  }

  private static DayFilter weekdayFilter(List<Integer> days) {
    List<Integer> ascending = sorted(days);
    if (ascending.equals(List.of(0, 1, 2, 3, 4, 5, 6))) {
      return DayFilter.every();
    }
    if (ascending.equals(List.of(1, 2, 3, 4, 5))) {
      return DayFilter.weekday();
    }
    if (ascending.equals(List.of(0, 6))) {
      return DayFilter.weekend();
    }
    return DayFilter.days(days.stream().map(d -> WEEKDAYS[d]).toList());
  }

  private static OptionalInt equalGap(List<TimeOfDay> times) {
    if (times.size() < 3) {
      return OptionalInt.empty();
    }
    int gap = times.get(1).totalMinutes() - times.get(0).totalMinutes();
    for (int i = 1; i < times.size(); i++) {
      if (times.get(i).totalMinutes() - times.get(i - 1).totalMinutes() != gap) {
        return OptionalInt.empty();
      }
    }
    return OptionalInt.of(gap);
  }

  private static IntervalRepeat interval(List<TimeOfDay> times, int gap, DayFilter days) {
    TimeOfDay from = times.getFirst();
    TimeOfDay last = times.getLast();
    TimeOfDay to =
        from.equals(MIDNIGHT) && last.totalMinutes() + gap >= MINUTES_PER_DAY ? END_OF_DAY : last;
    boolean hours = gap % 60 == 0;
    return new IntervalRepeat(
        hours ? gap / 60 : gap,
        hours ? IntervalUnit.HOURS : IntervalUnit.MINUTES,
        from,
        to,
        days.equals(DayFilter.every()) ? null : days);
  }

  private static HronException tooManyTimes(int count, OptionalInt gap) {
    if (gap.isPresent()) {
      return HronException.cron(INTERVAL_DAYS);
    }
    return HronException.cron(
        "not expressible in hron: " + count + " times a day are too many to list");
  }

  private static YearTarget yearTarget(Days days, List<Integer> months) {
    if (!(days instanceof Days.OfMonth(MonthTarget target)) || months.size() != 1) {
      return null;
    }
    MonthName month = MONTHS[months.getFirst() - 1];
    return switch (target.kind()) {
      case DAYS -> {
        List<DayOfMonthSpec> specs = target.specs();
        if (specs.size() == 1
            && specs.getFirst().kind() == DayOfMonthSpec.Kind.SINGLE
            && specs.getFirst().day() <= maxDay(month)) {
          yield YearTarget.date(month, specs.getFirst().day());
        }
        yield null;
      }
      case LAST_WEEKDAY -> YearTarget.lastWeekday(month);
      case ORDINAL_WEEKDAY -> YearTarget.ordinalWeekday(target.ordinal(), target.weekday(), month);
      case LAST_DAY, NEAREST_WEEKDAY -> null;
    };
  }

  private static int maxDay(MonthName month) {
    return switch (month) {
      case FEBRUARY -> 29;
      case APRIL, JUNE, SEPTEMBER, NOVEMBER -> 30;
      default -> 31;
    };
  }

  public static String toCron(ScheduleData data) throws HronException {
    if (!data.except().isEmpty()) {
      throw notExpressible("except clauses not supported");
    }
    if (data.until() != null) {
      throw notExpressible("until clauses not supported");
    }
    if (data.anchor() != null) {
      throw notExpressible("starting clauses not supported");
    }
    DayFields days = dayFields(data.expr());
    // A schedule built in code can have an empty day list, which writes an empty field.
    if (days.dayOfMonth().isEmpty() || days.dayOfWeek().isEmpty()) {
      throw notExpressible("schedule has no days");
    }
    String month = monthField(data);
    TimeFields times = timeFields(data.expr());
    return times.minute()
        + " "
        + times.hour()
        + " "
        + days.dayOfMonth()
        + " "
        + month
        + " "
        + days.dayOfWeek();
  }

  private static HronException notExpressible(String reason) {
    return HronException.cron("not expressible as cron: " + reason);
  }

  private static void repeatsOnce(int interval, String unit) throws HronException {
    if (interval > 1) {
      throw notExpressible("multi-" + unit + " repeats not supported");
    }
  }

  private static DayFields dayFields(ScheduleExpr expr) throws HronException {
    return switch (expr) {
      case IntervalRepeat ir ->
          new DayFields("*", ir.dayFilter() == null ? "*" : filterField(ir.dayFilter()));
      case DayRepeat dr -> {
        repeatsOnce(dr.interval(), "day");
        yield new DayFields("*", filterField(dr.days()));
      }
      case WeekRepeat wr -> {
        repeatsOnce(wr.interval(), "week");
        yield new DayFields("*", weekdaysField(wr.weekDays()));
      }
      case MonthRepeat mr -> {
        repeatsOnce(mr.interval(), "month");
        MonthTarget target = mr.target();
        yield switch (target.kind()) {
          case DAYS -> new DayFields(listField(sortedUnique(target.expandDays()), 31), "*");
          case LAST_DAY -> new DayFields("L", "*");
          case LAST_WEEKDAY -> new DayFields("LW", "*");
          case NEAREST_WEEKDAY -> {
            if (target.nearestDirection() != null) {
              throw notExpressible("directional nearest weekday not supported");
            }
            yield new DayFields(target.nearestWeekdayDay() + "W", "*");
          }
          case ORDINAL_WEEKDAY ->
              new DayFields("*", ordinalField(target.ordinal(), target.weekday()));
        };
      }
      case YearRepeat yr -> {
        repeatsOnce(yr.interval(), "year");
        YearTarget target = yr.target();
        yield switch (target.kind()) {
          case DATE, DAY_OF_MONTH -> new DayFields(String.valueOf(target.day()), "*");
          case ORDINAL_WEEKDAY ->
              new DayFields("*", ordinalField(target.ordinal(), target.weekday()));
          case LAST_WEEKDAY -> new DayFields("LW", "*");
        };
      }
      case SingleDate sd when sd.dateSpec().kind() == DateSpec.Kind.ISO ->
          throw notExpressible("ISO dates do not repeat");
      case SingleDate sd -> new DayFields(String.valueOf(sd.dateSpec().day()), "*");
    };
  }

  private static String monthField(ScheduleData data) throws HronException {
    List<MonthName> during = data.during();
    MonthName month = ownMonth(data.expr());
    if (month != null && !during.isEmpty() && !during.contains(month)) {
      throw notExpressible("during excludes the schedule's month");
    }
    if (month != null) {
      return String.valueOf(month.number());
    }
    if (during.isEmpty()) {
      return "*";
    }
    return listField(sortedUnique(during.stream().map(MonthName::number).toList()), 12);
  }

  private static MonthName ownMonth(ScheduleExpr expr) {
    return switch (expr) {
      case YearRepeat yr -> yr.target().month();
      case SingleDate sd when sd.dateSpec().kind() == DateSpec.Kind.NAMED -> sd.dateSpec().month();
      default -> null;
    };
  }

  private static TimeFields timeFields(ScheduleExpr expr) throws HronException {
    List<Integer> times = dailyTimes(expr);
    List<Integer> minutes = sortedUnique(times.stream().map(t -> t % 60).toList());
    List<Integer> hours = sortedUnique(times.stream().map(t -> t / 60).toList());
    // A schedule built in code can have no times, which no cron writes.
    if (times.isEmpty()) {
      throw notExpressible("schedule has no times");
    }
    if (minutes.size() * hours.size() != times.size()) {
      throw notExpressible("times are not every combination of their minutes and hours");
    }
    return new TimeFields(stepField(minutes, 60), stepField(hours, 24));
  }

  private static List<Integer> dailyTimes(ScheduleExpr expr) {
    List<TimeOfDay> times;
    switch (expr) {
      case IntervalRepeat ir -> {
        return Arrays.stream(Evaluator.intervalSlots(ir)).boxed().toList();
      }
      case DayRepeat dr -> times = dr.times();
      case WeekRepeat wr -> times = wr.times();
      case MonthRepeat mr -> times = mr.times();
      case YearRepeat yr -> times = yr.times();
      case SingleDate sd -> times = sd.times();
    }
    return sortedUnique(times.stream().map(TimeOfDay::totalMinutes).toList());
  }

  private static String filterField(DayFilter filter) {
    return switch (filter.kind()) {
      case EVERY -> "*";
      case WEEKDAY ->
          weekdaysField(
              List.of(
                  Weekday.MONDAY,
                  Weekday.TUESDAY,
                  Weekday.WEDNESDAY,
                  Weekday.THURSDAY,
                  Weekday.FRIDAY));
      case WEEKEND -> weekdaysField(List.of(Weekday.SATURDAY, Weekday.SUNDAY));
      case DAYS -> weekdaysField(filter.days());
    };
  }

  private static String weekdaysField(List<Weekday> days) {
    return listField(sortedUnique(days.stream().map(Weekday::cronDOW).toList()), 7);
  }

  private static String ordinalField(OrdinalPosition ordinal, Weekday weekday) {
    int day = weekday.cronDOW();
    for (int index = 0; index < ORDINALS.length; index++) {
      if (ORDINALS[index] == ordinal) {
        return day + "#" + (index + 1);
      }
    }
    return day + "L";
  }

  private static String stepField(List<Integer> values, int size) {
    int first = values.getFirst();
    int last = values.getLast();
    Integer gap = values.size() > 1 ? values.get(1) - first : null;
    boolean equalGaps = gap != null;
    for (int i = 1; equalGaps && i < values.size(); i++) {
      equalGaps = values.get(i) - values.get(i - 1) == gap;
    }
    if (values.size() == size) {
      return "*";
    }
    if (gap == null) {
      return String.valueOf(first);
    }
    if (equalGaps && first == 0 && last + gap == size) {
      return "*/" + gap;
    }
    if (equalGaps && gap == 1) {
      return first + "-" + last;
    }
    if (equalGaps && values.size() >= 3) {
      return first + "-" + last + "/" + gap;
    }
    return listField(values, size);
  }

  private static String listField(List<Integer> values, int size) {
    if (values.size() == size) {
      return "*";
    }
    return runs(values).stream()
        .map(run -> run[0] == run[1] ? String.valueOf(run[0]) : run[0] + "-" + run[1])
        .collect(Collectors.joining(","));
  }

  private static List<int[]> runs(List<Integer> sortedValues) {
    List<int[]> runs = new ArrayList<>();
    for (int value : sortedValues) {
      if (!runs.isEmpty() && runs.getLast()[1] + 1 == value) {
        runs.getLast()[1] = value;
      } else {
        runs.add(new int[] {value, value});
      }
    }
    return runs;
  }

  private static List<Integer> sorted(List<Integer> values) {
    List<Integer> copy = new ArrayList<>(values);
    copy.sort(null);
    return copy;
  }

  private static List<Integer> sortedUnique(Collection<Integer> values) {
    return new ArrayList<>(new TreeSet<>(values));
  }
}
