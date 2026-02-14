package io.hron.cron;

import io.hron.HronException;
import io.hron.ast.*;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Collectors;

/** Converts between hron expressions and 5-field cron expressions. */
public final class CronConverter {
  private CronConverter() {}

  /**
   * Converts a schedule to a 5-field cron expression.
   *
   * @param data the schedule data
   * @return the cron expression
   * @throws HronException if the schedule cannot be expressed as cron
   */
  public static String toCron(ScheduleData data) throws HronException {
    if (!data.except().isEmpty()) {
      throw HronException.cron("not expressible as cron (except clauses not supported)");
    }
    if (data.until() != null) {
      throw HronException.cron("not expressible as cron (until clauses not supported)");
    }
    if (!data.during().isEmpty()) {
      throw HronException.cron("not expressible as cron (during clauses not supported)");
    }

    return switch (data.expr()) {
      case DayRepeat dr -> dayRepeatToCron(dr);
      case IntervalRepeat ir -> intervalRepeatToCron(ir);
      case WeekRepeat _ ->
          throw HronException.cron("not expressible as cron (multi-week intervals not supported)");
      case MonthRepeat mr -> monthRepeatToCron(mr);
      case OrdinalRepeat _ ->
          throw HronException.cron(
              "not expressible as cron (ordinal weekday of month not supported)");
      case SingleDate _ ->
          throw HronException.cron("not expressible as cron (single dates are not repeating)");
      case YearRepeat _ ->
          throw HronException.cron(
              "not expressible as cron (yearly schedules not supported in 5-field cron)");
    };
  }

  private static String dayRepeatToCron(DayRepeat dr) throws HronException {
    if (dr.interval() > 1) {
      throw HronException.cron("not expressible as cron (multi-day intervals not supported)");
    }
    if (dr.times().size() != 1) {
      throw HronException.cron("not expressible as cron (multiple times not supported)");
    }

    TimeOfDay t = dr.times().getFirst();
    String dow = dayFilterToCronDOW(dr.days());

    return String.format("%d %d * * %s", t.minute(), t.hour(), dow);
  }

  private static String intervalRepeatToCron(IntervalRepeat ir) throws HronException {
    boolean fullDay =
        ir.fromTime().hour() == 0
            && ir.fromTime().minute() == 0
            && ir.toTime().hour() == 23
            && ir.toTime().minute() == 59;

    if (!fullDay) {
      throw HronException.cron(
          "not expressible as cron (partial-day interval windows not supported)");
    }
    if (ir.dayFilter() != null) {
      throw HronException.cron("not expressible as cron (interval with day filter not supported)");
    }

    if (ir.unit() == IntervalUnit.MINUTES) {
      if (60 % ir.interval() != 0) {
        throw HronException.cron(
            "not expressible as cron (*/" + ir.interval() + " breaks at hour boundaries)");
      }
      return String.format("*/%d * * * *", ir.interval());
    }

    // Hours
    return String.format("0 */%d * * *", ir.interval());
  }

  private static String monthRepeatToCron(MonthRepeat mr) throws HronException {
    if (mr.interval() > 1) {
      throw HronException.cron("not expressible as cron (multi-month intervals not supported)");
    }
    if (mr.times().size() != 1) {
      throw HronException.cron("not expressible as cron (multiple times not supported)");
    }

    TimeOfDay t = mr.times().getFirst();

    return switch (mr.target().kind()) {
      case DAYS -> {
        List<Integer> days = mr.target().expandDays();
        String dom = formatIntList(days);
        yield String.format("%d %d %s * *", t.minute(), t.hour(), dom);
      }
      case LAST_DAY ->
          throw HronException.cron("not expressible as cron (last day of month not supported)");
      case LAST_WEEKDAY ->
          throw HronException.cron("not expressible as cron (last weekday of month not supported)");
      case NEAREST_WEEKDAY -> {
        if (mr.target().nearestDirection() != null) {
          throw HronException.cron(
              "not expressible as cron (directional nearest weekday not supported)");
        }
        yield String.format(
            "%d %d %dW * *", t.minute(), t.hour(), mr.target().nearestWeekdayDay());
      }
    };
  }

  private static String dayFilterToCronDOW(DayFilter f) {
    return switch (f.kind()) {
      case EVERY -> "*";
      case WEEKDAY -> "1-5";
      case WEEKEND -> "0,6";
      case DAYS -> {
        List<Integer> nums = f.days().stream().map(Weekday::cronDOW).sorted().toList();
        yield formatIntList(nums);
      }
    };
  }

  private static String formatIntList(List<Integer> nums) {
    return nums.stream().map(String::valueOf).collect(Collectors.joining(","));
  }

  /**
   * Converts a 5-field cron expression to a ScheduleData.
   *
   * @param cron the cron expression
   * @return the schedule data
   * @throws HronException if the cron expression is invalid
   */
  public static ScheduleData fromCron(String cron) throws HronException {
    cron = cron.trim();

    // Handle @ shortcuts first
    if (cron.startsWith("@")) {
      return parseCronShortcut(cron);
    }

    String[] fields = cron.split("\\s+");
    if (fields.length != 5) {
      throw HronException.cron("expected 5 cron fields, got " + fields.length);
    }

    String minuteField = fields[0];
    String hourField = fields[1];
    String domField = fields[2];
    String monthField = fields[3];
    String dowField = fields[4];

    // Normalize ? to * (they're semantically equivalent for our purposes)
    if (domField.equals("?")) {
      domField = "*";
    }
    if (dowField.equals("?")) {
      dowField = "*";
    }

    // Parse month field into during clause
    List<MonthName> during = parseMonthField(monthField);

    // Check for special DOW patterns: nth weekday (#), last weekday (5L)
    ScheduleData nthResult = tryParseNthWeekday(minuteField, hourField, domField, dowField, during);
    if (nthResult != null) {
      return nthResult;
    }

    // Check for L (last day) or LW (last weekday) in DOM
    ScheduleData lastResult = tryParseLastDay(minuteField, hourField, domField, dowField, during);
    if (lastResult != null) {
      return lastResult;
    }

    // Check for W (nearest weekday): e.g., 15W
    if (domField.endsWith("W") && !domField.equals("LW")) {
      ScheduleData wResult =
          tryParseNearestWeekday(minuteField, hourField, domField, dowField, during);
      if (wResult != null) {
        return wResult;
      }
    }

    // Check for interval patterns: */N or range/N
    ScheduleData intervalResult =
        tryParseInterval(minuteField, hourField, domField, dowField, during);
    if (intervalResult != null) {
      return intervalResult;
    }

    // Standard time-based cron
    int minute = parseSingleValue(minuteField, "minute", 0, 59);
    int hour = parseSingleValue(hourField, "hour", 0, 23);
    TimeOfDay time = new TimeOfDay(hour, minute);

    // DOM-based (monthly) - when DOM is specified and DOW is *
    if (!domField.equals("*") && dowField.equals("*")) {
      MonthTarget target = parseDomField(domField);
      ScheduleExpr expr = new MonthRepeat(1, target, List.of(time));
      return new ScheduleData(expr, null, List.of(), null, null, during);
    }

    // DOW-based (day repeat)
    DayFilter days = parseCronDOW(dowField);
    ScheduleExpr expr = new DayRepeat(1, days, List.of(time));
    return new ScheduleData(expr, null, List.of(), null, null, during);
  }

  /** Parse @ shortcuts like @daily, @hourly, etc. */
  private static ScheduleData parseCronShortcut(String cron) throws HronException {
    String lower = cron.toLowerCase();
    return switch (lower) {
      case "@yearly", "@annually" ->
          ScheduleData.of(
              new YearRepeat(
                  1, YearTarget.date(MonthName.JANUARY, 1), List.of(new TimeOfDay(0, 0))));
      case "@monthly" ->
          ScheduleData.of(
              new MonthRepeat(
                  1,
                  MonthTarget.days(List.of(DayOfMonthSpec.single(1))),
                  List.of(new TimeOfDay(0, 0))));
      case "@weekly" ->
          ScheduleData.of(
              new DayRepeat(
                  1, DayFilter.days(List.of(Weekday.SUNDAY)), List.of(new TimeOfDay(0, 0))));
      case "@daily", "@midnight" ->
          ScheduleData.of(new DayRepeat(1, DayFilter.every(), List.of(new TimeOfDay(0, 0))));
      case "@hourly" ->
          ScheduleData.of(
              new IntervalRepeat(
                  1, IntervalUnit.HOURS, new TimeOfDay(0, 0), new TimeOfDay(23, 59), null));
      default -> throw HronException.cron("unknown @ shortcut: " + cron);
    };
  }

  /** Parse month field into a List of MonthName for the during clause. */
  private static List<MonthName> parseMonthField(String field) throws HronException {
    if (field.equals("*")) {
      return List.of();
    }

    List<MonthName> months = new ArrayList<>();
    for (String part : field.split(",")) {
      // Check for step values FIRST (e.g., 1-12/3 or */3)
      if (part.contains("/")) {
        String[] stepParts = part.split("/", 2);
        String rangePart = stepParts[0];
        String stepStr = stepParts[1];

        int start, end;
        if (rangePart.equals("*")) {
          start = 1;
          end = 12;
        } else if (rangePart.contains("-")) {
          String[] rangeBounds = rangePart.split("-", 2);
          MonthName startMonth = parseMonthValue(rangeBounds[0]);
          MonthName endMonth = parseMonthValue(rangeBounds[1]);
          start = startMonth.number();
          end = endMonth.number();
        } else {
          throw HronException.cron("invalid month step expression: " + part);
        }

        int step;
        try {
          step = Integer.parseInt(stepStr);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid month step value: " + stepStr);
        }
        if (step == 0) {
          throw HronException.cron("step cannot be 0");
        }

        for (int n = start; n <= end; n += step) {
          months.add(monthFromNumber(n));
        }
      } else if (part.contains("-")) {
        // Range like 1-3 or JAN-MAR
        String[] rangeBounds = part.split("-", 2);
        MonthName startMonth = parseMonthValue(rangeBounds[0]);
        MonthName endMonth = parseMonthValue(rangeBounds[1]);
        int startNum = startMonth.number();
        int endNum = endMonth.number();
        if (startNum > endNum) {
          throw HronException.cron(
              "invalid month range: " + rangeBounds[0] + " > " + rangeBounds[1]);
        }
        for (int n = startNum; n <= endNum; n++) {
          months.add(monthFromNumber(n));
        }
      } else {
        // Single month
        months.add(parseMonthValue(part));
      }
    }

    return months;
  }

  /** Parse a single month value (number 1-12 or name JAN-DEC). */
  private static MonthName parseMonthValue(String s) throws HronException {
    // Try as number first
    try {
      int n = Integer.parseInt(s);
      return monthFromNumber(n);
    } catch (NumberFormatException e) {
      // Not a number, try as name
    }
    // Try as name
    return parseMonthName(s);
  }

  private static MonthName monthFromNumber(int n) throws HronException {
    return switch (n) {
      case 1 -> MonthName.JANUARY;
      case 2 -> MonthName.FEBRUARY;
      case 3 -> MonthName.MARCH;
      case 4 -> MonthName.APRIL;
      case 5 -> MonthName.MAY;
      case 6 -> MonthName.JUNE;
      case 7 -> MonthName.JULY;
      case 8 -> MonthName.AUGUST;
      case 9 -> MonthName.SEPTEMBER;
      case 10 -> MonthName.OCTOBER;
      case 11 -> MonthName.NOVEMBER;
      case 12 -> MonthName.DECEMBER;
      default -> throw HronException.cron("invalid month number: " + n);
    };
  }

  private static MonthName parseMonthName(String s) throws HronException {
    return MonthName.parse(s).orElseThrow(() -> HronException.cron("invalid month: " + s));
  }

  /** Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday). */
  private static ScheduleData tryParseNthWeekday(
      String minuteField,
      String hourField,
      String domField,
      String dowField,
      List<MonthName> during)
      throws HronException {
    // Check for # pattern (nth weekday of month)
    if (dowField.contains("#")) {
      String[] parts = dowField.split("#", 2);
      String dowStr = parts[0];
      String nthStr = parts[1];

      int dowNum = parseDowValue(dowStr);
      Weekday weekday = cronDowToWeekday(dowNum);

      int nth;
      try {
        nth = Integer.parseInt(nthStr);
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid nth value: " + nthStr);
      }
      if (nth < 1 || nth > 5) {
        throw HronException.cron("nth must be 1-5, got " + nth);
      }

      OrdinalPosition ordinal =
          switch (nth) {
            case 1 -> OrdinalPosition.FIRST;
            case 2 -> OrdinalPosition.SECOND;
            case 3 -> OrdinalPosition.THIRD;
            case 4 -> OrdinalPosition.FOURTH;
            case 5 -> OrdinalPosition.FIFTH;
            default -> throw HronException.cron("invalid nth value: " + nth);
          };

      if (!domField.equals("*") && !domField.equals("?")) {
        throw HronException.cron("DOM must be * when using # for nth weekday");
      }

      int minute = parseSingleValue(minuteField, "minute", 0, 59);
      int hour = parseSingleValue(hourField, "hour", 0, 23);

      ScheduleExpr expr =
          new OrdinalRepeat(1, ordinal, weekday, List.of(new TimeOfDay(hour, minute)));
      return new ScheduleData(expr, null, List.of(), null, null, during);
    }

    // Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
    if (dowField.endsWith("L") && dowField.length() > 1) {
      String dowStr = dowField.substring(0, dowField.length() - 1);
      int dowNum = parseDowValue(dowStr);
      Weekday weekday = cronDowToWeekday(dowNum);

      if (!domField.equals("*") && !domField.equals("?")) {
        throw HronException.cron("DOM must be * when using nL for last weekday");
      }

      int minute = parseSingleValue(minuteField, "minute", 0, 59);
      int hour = parseSingleValue(hourField, "hour", 0, 23);

      ScheduleExpr expr =
          new OrdinalRepeat(1, OrdinalPosition.LAST, weekday, List.of(new TimeOfDay(hour, minute)));
      return new ScheduleData(expr, null, List.of(), null, null, during);
    }

    return null;
  }

  /** Try to parse L (last day) or LW (last weekday) patterns. */
  private static ScheduleData tryParseLastDay(
      String minuteField,
      String hourField,
      String domField,
      String dowField,
      List<MonthName> during)
      throws HronException {
    if (!domField.equals("L") && !domField.equals("LW")) {
      return null;
    }

    if (!dowField.equals("*") && !dowField.equals("?")) {
      throw HronException.cron("DOW must be * when using L or LW in DOM");
    }

    int minute = parseSingleValue(minuteField, "minute", 0, 59);
    int hour = parseSingleValue(hourField, "hour", 0, 23);

    MonthTarget target = domField.equals("LW") ? MonthTarget.lastWeekday() : MonthTarget.lastDay();

    ScheduleExpr expr = new MonthRepeat(1, target, List.of(new TimeOfDay(hour, minute)));
    return new ScheduleData(expr, null, List.of(), null, null, during);
  }

  /** Try to parse W (nearest weekday) patterns: 15W, 1W, etc. */
  private static ScheduleData tryParseNearestWeekday(
      String minuteField,
      String hourField,
      String domField,
      String dowField,
      List<MonthName> during)
      throws HronException {
    if (!domField.endsWith("W") || domField.equals("LW")) {
      return null;
    }

    if (!dowField.equals("*") && !dowField.equals("?")) {
      throw HronException.cron("DOW must be * when using W in DOM");
    }

    String dayStr = domField.substring(0, domField.length() - 1);
    int day;
    try {
      day = Integer.parseInt(dayStr);
    } catch (NumberFormatException e) {
      throw HronException.cron("invalid W day: " + dayStr);
    }

    if (day < 1 || day > 31) {
      throw HronException.cron("W day must be 1-31, got " + day);
    }

    int minute = parseSingleValue(minuteField, "minute", 0, 59);
    int hour = parseSingleValue(hourField, "hour", 0, 23);

    MonthTarget target = MonthTarget.nearestWeekday(day);
    ScheduleExpr expr = new MonthRepeat(1, target, List.of(new TimeOfDay(hour, minute)));
    return new ScheduleData(expr, null, List.of(), null, null, during);
  }

  /** Try to parse interval patterns like *&#47;N, range/N in minute or hour fields. */
  private static ScheduleData tryParseInterval(
      String minuteField,
      String hourField,
      String domField,
      String dowField,
      List<MonthName> during)
      throws HronException {
    // Minute interval: */N or range/N
    if (minuteField.contains("/")) {
      String[] parts = minuteField.split("/", 2);
      String rangePart = parts[0];
      String stepStr = parts[1];

      int interval;
      try {
        interval = Integer.parseInt(stepStr);
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid minute interval value");
      }

      if (interval == 0) {
        throw HronException.cron("step cannot be 0");
      }

      int fromMinute, toMinute;
      if (rangePart.equals("*")) {
        fromMinute = 0;
        toMinute = 59;
      } else if (rangePart.contains("-")) {
        String[] rangeBounds = rangePart.split("-", 2);
        try {
          fromMinute = Integer.parseInt(rangeBounds[0]);
          toMinute = Integer.parseInt(rangeBounds[1]);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid minute range");
        }
        if (fromMinute > toMinute) {
          throw HronException.cron("range start must be <= end: " + fromMinute + "-" + toMinute);
        }
      } else {
        // Single value with step (e.g., 0/15) - treat as starting point
        try {
          fromMinute = Integer.parseInt(rangePart);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid minute value");
        }
        toMinute = 59;
      }

      // Determine the hour window
      int fromHour, toHour;
      if (hourField.equals("*")) {
        fromHour = 0;
        toHour = 23;
      } else if (hourField.contains("-")) {
        String[] rangeBounds = hourField.split("-", 2);
        try {
          fromHour = Integer.parseInt(rangeBounds[0]);
          toHour = Integer.parseInt(rangeBounds[1]);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid hour range");
        }
      } else if (hourField.contains("/")) {
        // Hour also has step - this is complex, handle as hour interval
        return null;
      } else {
        try {
          fromHour = toHour = Integer.parseInt(hourField);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid hour");
        }
      }

      // Check if this should be a day filter
      DayFilter dayFilter = null;
      if (!dowField.equals("*")) {
        dayFilter = parseCronDOW(dowField);
      }

      if (domField.equals("*") || domField.equals("?")) {
        // Determine the end minute based on context
        int endMinute;
        if (fromMinute == 0 && toMinute == 59 && toHour == 23) {
          // Full day: 00:00 to 23:59
          endMinute = 59;
        } else if (fromMinute == 0 && toMinute == 59) {
          // Partial day with full minutes range: use :00 for cleaner output
          endMinute = 0;
        } else {
          endMinute = toMinute;
        }

        ScheduleExpr expr =
            new IntervalRepeat(
                interval,
                IntervalUnit.MINUTES,
                new TimeOfDay(fromHour, fromMinute),
                new TimeOfDay(toHour, endMinute),
                dayFilter);
        return new ScheduleData(expr, null, List.of(), null, null, during);
      }
    }

    // Hour interval: 0 */N or 0 range/N
    if (hourField.contains("/") && (minuteField.equals("0") || minuteField.equals("00"))) {
      String[] parts = hourField.split("/", 2);
      String rangePart = parts[0];
      String stepStr = parts[1];

      int interval;
      try {
        interval = Integer.parseInt(stepStr);
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid hour interval value");
      }

      if (interval == 0) {
        throw HronException.cron("step cannot be 0");
      }

      int fromHour, toHour;
      if (rangePart.equals("*")) {
        fromHour = 0;
        toHour = 23;
      } else if (rangePart.contains("-")) {
        String[] rangeBounds = rangePart.split("-", 2);
        try {
          fromHour = Integer.parseInt(rangeBounds[0]);
          toHour = Integer.parseInt(rangeBounds[1]);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid hour range");
        }
        if (fromHour > toHour) {
          throw HronException.cron("range start must be <= end: " + fromHour + "-" + toHour);
        }
      } else {
        try {
          fromHour = Integer.parseInt(rangePart);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid hour value");
        }
        toHour = 23;
      }

      if ((domField.equals("*") || domField.equals("?"))
          && (dowField.equals("*") || dowField.equals("?"))) {
        // Use :59 only for full day (00:00 to 23:59), otherwise use :00
        int endMinute = (fromHour == 0 && toHour == 23) ? 59 : 0;

        ScheduleExpr expr =
            new IntervalRepeat(
                interval,
                IntervalUnit.HOURS,
                new TimeOfDay(fromHour, 0),
                new TimeOfDay(toHour, endMinute),
                null);
        return new ScheduleData(expr, null, List.of(), null, null, during);
      }
    }

    return null;
  }

  /** Parse a DOM field into a MonthTarget. */
  private static MonthTarget parseDomField(String field) throws HronException {
    List<DayOfMonthSpec> specs = new ArrayList<>();

    for (String part : field.split(",")) {
      if (part.contains("/")) {
        // Step value: 1-31/2 or */5
        String[] stepParts = part.split("/", 2);
        String rangePart = stepParts[0];
        String stepStr = stepParts[1];

        int start, end;
        if (rangePart.equals("*")) {
          start = 1;
          end = 31;
        } else if (rangePart.contains("-")) {
          String[] rangeBounds = rangePart.split("-", 2);
          try {
            start = Integer.parseInt(rangeBounds[0]);
            end = Integer.parseInt(rangeBounds[1]);
          } catch (NumberFormatException e) {
            throw HronException.cron("invalid DOM range: " + rangePart);
          }
          if (start > end) {
            throw HronException.cron("range start must be <= end: " + start + "-" + end);
          }
        } else {
          try {
            start = Integer.parseInt(rangePart);
          } catch (NumberFormatException e) {
            throw HronException.cron("invalid DOM value: " + rangePart);
          }
          end = 31;
        }

        int step;
        try {
          step = Integer.parseInt(stepStr);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid DOM step: " + stepStr);
        }
        if (step == 0) {
          throw HronException.cron("step cannot be 0");
        }

        validateDom(start);
        validateDom(end);

        for (int d = start; d <= end; d += step) {
          specs.add(DayOfMonthSpec.single(d));
        }
      } else if (part.contains("-")) {
        // Range: 1-5
        String[] rangeBounds = part.split("-", 2);
        int start, end;
        try {
          start = Integer.parseInt(rangeBounds[0]);
          end = Integer.parseInt(rangeBounds[1]);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid DOM range: " + part);
        }
        if (start > end) {
          throw HronException.cron("range start must be <= end: " + start + "-" + end);
        }
        validateDom(start);
        validateDom(end);
        specs.add(DayOfMonthSpec.range(start, end));
      } else {
        // Single: 15
        int day;
        try {
          day = Integer.parseInt(part);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid DOM value: " + part);
        }
        validateDom(day);
        specs.add(DayOfMonthSpec.single(day));
      }
    }

    return MonthTarget.days(specs);
  }

  private static void validateDom(int day) throws HronException {
    if (day < 1 || day > 31) {
      throw HronException.cron("DOM must be 1-31, got " + day);
    }
  }

  /** Parse a DOW field into a DayFilter. */
  private static DayFilter parseCronDOW(String field) throws HronException {
    if (field.equals("*")) {
      return DayFilter.every();
    }

    List<Weekday> days = new ArrayList<>();

    for (String part : field.split(",")) {
      if (part.contains("/")) {
        // Step value: 0-6/2 or */2
        String[] stepParts = part.split("/", 2);
        String rangePart = stepParts[0];
        String stepStr = stepParts[1];

        int start, end;
        if (rangePart.equals("*")) {
          start = 0;
          end = 6;
        } else if (rangePart.contains("-")) {
          String[] rangeBounds = rangePart.split("-", 2);
          start = parseDowValueRaw(rangeBounds[0]);
          end = parseDowValueRaw(rangeBounds[1]);
          if (start > end) {
            throw HronException.cron(
                "range start must be <= end: " + rangeBounds[0] + "-" + rangeBounds[1]);
          }
        } else {
          start = parseDowValueRaw(rangePart);
          end = 6;
        }

        int step;
        try {
          step = Integer.parseInt(stepStr);
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid DOW step: " + stepStr);
        }
        if (step == 0) {
          throw HronException.cron("step cannot be 0");
        }

        for (int d = start; d <= end; d += step) {
          days.add(cronDowToWeekday(d));
        }
      } else if (part.contains("-")) {
        // Range: 1-5 or MON-FRI
        // Parse without normalizing 7 to 0 for range purposes
        String[] rangeBounds = part.split("-", 2);
        int start = parseDowValueRaw(rangeBounds[0]);
        int end = parseDowValueRaw(rangeBounds[1]);
        if (start > end) {
          throw HronException.cron(
              "range start must be <= end: " + rangeBounds[0] + "-" + rangeBounds[1]);
        }
        for (int d = start; d <= end; d++) {
          // Normalize 7 to 0 (Sunday) when converting to weekday
          int normalized = (d == 7) ? 0 : d;
          days.add(cronDowToWeekday(normalized));
        }
      } else {
        // Single: 1 or MON
        int dow = parseDowValue(part);
        days.add(cronDowToWeekday(dow));
      }
    }

    // Check for special patterns
    if (days.size() == 5) {
      List<Weekday> sorted = new ArrayList<>(days);
      sorted.sort((a, b) -> Integer.compare(a.number(), b.number()));
      List<Weekday> weekdays =
          List.of(
              Weekday.MONDAY, Weekday.TUESDAY, Weekday.WEDNESDAY, Weekday.THURSDAY, Weekday.FRIDAY);
      if (sorted.equals(weekdays)) {
        return DayFilter.weekday();
      }
    }
    if (days.size() == 2) {
      List<Weekday> sorted = new ArrayList<>(days);
      sorted.sort((a, b) -> Integer.compare(a.number(), b.number()));
      List<Weekday> weekend = List.of(Weekday.SATURDAY, Weekday.SUNDAY);
      if (sorted.equals(weekend)) {
        return DayFilter.weekend();
      }
    }

    return DayFilter.days(days);
  }

  /** Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0. */
  private static int parseDowValue(String s) throws HronException {
    int raw = parseDowValueRaw(s);
    // Normalize 7 to 0 (both mean Sunday)
    return (raw == 7) ? 0 : raw;
  }

  /** Parse a DOW value without normalizing 7 to 0 (for range checking). */
  private static int parseDowValueRaw(String s) throws HronException {
    // Try as number first
    try {
      int n = Integer.parseInt(s);
      if (n > 7) {
        throw HronException.cron("DOW must be 0-7, got " + n);
      }
      return n;
    } catch (NumberFormatException e) {
      // Not a number, try as name
    }
    // Try as name
    String upper = s.toUpperCase();
    return switch (upper) {
      case "SUN" -> 0;
      case "MON" -> 1;
      case "TUE" -> 2;
      case "WED" -> 3;
      case "THU" -> 4;
      case "FRI" -> 5;
      case "SAT" -> 6;
      default -> throw HronException.cron("invalid DOW: " + s);
    };
  }

  private static Weekday cronDowToWeekday(int n) throws HronException {
    return switch (n) {
      case 0, 7 -> Weekday.SUNDAY;
      case 1 -> Weekday.MONDAY;
      case 2 -> Weekday.TUESDAY;
      case 3 -> Weekday.WEDNESDAY;
      case 4 -> Weekday.THURSDAY;
      case 5 -> Weekday.FRIDAY;
      case 6 -> Weekday.SATURDAY;
      default -> throw HronException.cron("invalid DOW number: " + n);
    };
  }

  /** Parse a single numeric value with validation. */
  private static int parseSingleValue(String field, String name, int min, int max)
      throws HronException {
    int value;
    try {
      value = Integer.parseInt(field);
    } catch (NumberFormatException e) {
      throw HronException.cron("invalid " + name + " field: " + field);
    }
    if (value < min || value > max) {
      throw HronException.cron(name + " must be " + min + "-" + max + ", got " + value);
    }
    return value;
  }
}
