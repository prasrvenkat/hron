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
    String[] fields = cron.trim().split("\\s+");
    if (fields.length != 5) {
      throw HronException.cron("expected 5 cron fields, got " + fields.length);
    }

    String minuteField = fields[0];
    String hourField = fields[1];
    String domField = fields[2];
    // String monthField = fields[3]; // not used
    String dowField = fields[4];

    // Minute interval: */N
    if (minuteField.startsWith("*/")) {
      int interval;
      try {
        interval = Integer.parseInt(minuteField.substring(2));
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid minute interval");
      }

      int fromHour = 0;
      int toHour = 23;

      if (!hourField.equals("*")) {
        if (hourField.contains("-")) {
          String[] parts = hourField.split("-");
          if (parts.length != 2) {
            throw HronException.cron("invalid hour range");
          }
          try {
            fromHour = Integer.parseInt(parts[0]);
            toHour = Integer.parseInt(parts[1]);
          } catch (NumberFormatException e) {
            throw HronException.cron("invalid hour range");
          }
        } else {
          try {
            fromHour = toHour = Integer.parseInt(hourField);
          } catch (NumberFormatException e) {
            throw HronException.cron("invalid hour");
          }
        }
      }

      DayFilter dayFilter = null;
      if (!dowField.equals("*")) {
        dayFilter = parseCronDOW(dowField);
      }

      if (domField.equals("*")) {
        int toMin = toHour != 23 ? 0 : 59;
        return ScheduleData.of(
            new IntervalRepeat(
                interval,
                IntervalUnit.MINUTES,
                new TimeOfDay(fromHour, 0),
                new TimeOfDay(toHour, toMin),
                dayFilter));
      }
    }

    // Hour interval: 0 */N
    if (hourField.startsWith("*/") && minuteField.equals("0")) {
      int interval;
      try {
        interval = Integer.parseInt(hourField.substring(2));
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid hour interval");
      }

      if (domField.equals("*") && dowField.equals("*")) {
        return ScheduleData.of(
            new IntervalRepeat(
                interval, IntervalUnit.HOURS, new TimeOfDay(0, 0), new TimeOfDay(23, 59), null));
      }
    }

    // Standard time-based cron
    int minute;
    int hour;
    try {
      minute = Integer.parseInt(minuteField);
      hour = Integer.parseInt(hourField);
    } catch (NumberFormatException e) {
      throw HronException.cron("invalid minute/hour field: " + minuteField + " " + hourField);
    }

    TimeOfDay t = new TimeOfDay(hour, minute);

    // DOM-based (monthly)
    if (!domField.equals("*") && dowField.equals("*")) {
      if (domField.contains("-")) {
        throw HronException.cron("DOM ranges not supported: " + domField);
      }

      List<DayOfMonthSpec> specs = new ArrayList<>();
      for (String s : domField.split(",")) {
        try {
          int day = Integer.parseInt(s);
          specs.add(DayOfMonthSpec.single(day));
        } catch (NumberFormatException e) {
          throw HronException.cron("invalid DOM field: " + domField);
        }
      }

      return ScheduleData.of(new MonthRepeat(1, MonthTarget.days(specs), List.of(t)));
    }

    // DOW-based (day repeat)
    DayFilter days = parseCronDOW(dowField);
    return ScheduleData.of(new DayRepeat(1, days, List.of(t)));
  }

  private static DayFilter parseCronDOW(String field) throws HronException {
    if (field.equals("*")) {
      return DayFilter.every();
    }
    if (field.equals("1-5")) {
      return DayFilter.weekday();
    }
    if (field.equals("0,6") || field.equals("6,0")) {
      return DayFilter.weekend();
    }

    if (field.contains("-")) {
      throw HronException.cron("DOW ranges not supported: " + field);
    }

    List<Weekday> days = new ArrayList<>();
    for (String s : field.split(",")) {
      int n;
      try {
        n = Integer.parseInt(s);
      } catch (NumberFormatException e) {
        throw HronException.cron("invalid DOW field: " + field);
      }

      Weekday wd = cronDOWToWeekday(n);
      if (wd == null) {
        throw HronException.cron("invalid DOW number: " + n);
      }
      days.add(wd);
    }

    return DayFilter.days(days);
  }

  private static Weekday cronDOWToWeekday(int n) {
    return switch (n) {
      case 0, 7 -> Weekday.SUNDAY;
      case 1 -> Weekday.MONDAY;
      case 2 -> Weekday.TUESDAY;
      case 3 -> Weekday.WEDNESDAY;
      case 4 -> Weekday.THURSDAY;
      case 5 -> Weekday.FRIDAY;
      case 6 -> Weekday.SATURDAY;
      default -> null;
    };
  }
}
