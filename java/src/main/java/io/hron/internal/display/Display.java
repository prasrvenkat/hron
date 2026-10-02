package io.hron.internal.display;

import io.hron.Schedule;
import io.hron.ast.*;
import java.util.List;
import java.util.stream.Collectors;

public final class Display {
  private Display() {}

  public static String render(Schedule schedule) {
    StringBuilder sb = new StringBuilder();

    sb.append(renderExpr(schedule.expression()));

    if (!schedule.except().isEmpty()) {
      sb.append(" except ");
      sb.append(renderExceptions(schedule.except()));
    }

    schedule.until().ifPresent(until -> sb.append(" until ").append(renderUntil(until)));
    schedule.starting().ifPresent(starting -> sb.append(" starting ").append(starting));

    if (!schedule.during().isEmpty()) {
      sb.append(" during ");
      sb.append(renderMonthList(schedule.during()));
    }

    schedule.timezone().ifPresent(timezone -> sb.append(" in ").append(timezone));

    return sb.toString();
  }

  private static String renderExpr(ScheduleExpr expr) {
    return switch (expr) {
      case DayRepeat dr -> renderDayRepeat(dr);
      case IntervalRepeat ir -> renderIntervalRepeat(ir);
      case WeekRepeat wr -> renderWeekRepeat(wr);
      case MonthRepeat mr -> renderMonthRepeat(mr);
      case SingleDate sd -> renderSingleDate(sd);
      case YearRepeat yr -> renderYearRepeat(yr);
    };
  }

  private static String renderDayRepeat(DayRepeat dr) {
    if (dr.interval() > 1) {
      return String.format("every %d days at %s", dr.interval(), formatTimeList(dr.times()));
    }
    return String.format("every %s at %s", renderDayFilter(dr.days()), formatTimeList(dr.times()));
  }

  private static String renderIntervalRepeat(IntervalRepeat ir) {
    StringBuilder sb = new StringBuilder();
    sb.append(
        String.format(
            "every %d %s from %s to %s",
            ir.interval(), ir.unit().display(ir.interval()), ir.fromTime(), ir.toTime()));
    if (ir.dayFilter() != null) {
      sb.append(" on ");
      sb.append(renderDayFilter(ir.dayFilter()));
    }
    return sb.toString();
  }

  private static String renderWeekRepeat(WeekRepeat wr) {
    if (wr.interval() > 1) {
      return String.format(
          "every %d weeks on %s at %s",
          wr.interval(), formatDayList(wr.weekDays()), formatTimeList(wr.times()));
    }
    return String.format(
        "every week on %s at %s", formatDayList(wr.weekDays()), formatTimeList(wr.times()));
  }

  private static String renderMonthRepeat(MonthRepeat mr) {
    String targetStr = renderMonthTarget(mr.target());
    if (mr.interval() > 1) {
      return String.format(
          "every %d months on the %s at %s", mr.interval(), targetStr, formatTimeList(mr.times()));
    }
    return String.format("every month on the %s at %s", targetStr, formatTimeList(mr.times()));
  }

  private static String renderSingleDate(SingleDate sd) {
    return String.format("on %s at %s", renderDateSpec(sd.dateSpec()), formatTimeList(sd.times()));
  }

  private static String renderYearRepeat(YearRepeat yr) {
    String targetStr = renderYearTarget(yr.target());
    if (yr.interval() > 1) {
      return String.format(
          "every %d years on %s at %s", yr.interval(), targetStr, formatTimeList(yr.times()));
    }
    return String.format("every year on %s at %s", targetStr, formatTimeList(yr.times()));
  }

  private static String renderDayFilter(DayFilter f) {
    return switch (f.kind()) {
      case EVERY -> "day";
      case WEEKDAY -> "weekday";
      case WEEKEND -> "weekend";
      case DAYS -> formatDayList(f.days());
    };
  }

  private static String renderMonthTarget(MonthTarget target) {
    return switch (target.kind()) {
      case LAST_DAY -> "last day";
      case LAST_WEEKDAY -> "last weekday";
      case DAYS -> formatOrdinalDaySpecs(target.specs());
      case NEAREST_WEEKDAY -> {
        StringBuilder sb = new StringBuilder();
        if (target.nearestDirection() != null) {
          switch (target.nearestDirection()) {
            case NEXT -> sb.append("next ");
            case PREVIOUS -> sb.append("previous ");
          }
        }
        sb.append("nearest weekday to ");
        sb.append(ordinalNumber(target.nearestWeekdayDay()));
        yield sb.toString();
      }
      case ORDINAL_WEEKDAY -> String.format("%s %s", target.ordinal(), target.weekday());
    };
  }

  private static String renderYearTarget(YearTarget target) {
    return switch (target.kind()) {
      case DATE -> String.format("%s %d", target.month(), target.day());
      case ORDINAL_WEEKDAY ->
          String.format("the %s %s of %s", target.ordinal(), target.weekday(), target.month());
      case DAY_OF_MONTH ->
          String.format("the %s of %s", ordinalNumber(target.day()), target.month());
      case LAST_WEEKDAY -> String.format("the last weekday of %s", target.month());
    };
  }

  private static String renderDateSpec(DateSpec spec) {
    return switch (spec.kind()) {
      case NAMED -> String.format("%s %d", spec.month(), spec.day());
      case ISO -> spec.date();
    };
  }

  private static String renderExceptions(List<ExceptionSpec> exceptions) {
    return exceptions.stream().map(Display::renderExceptionSpec).collect(Collectors.joining(", "));
  }

  private static String renderExceptionSpec(ExceptionSpec exc) {
    return switch (exc.kind()) {
      case NAMED -> String.format("%s %d", exc.month(), exc.day());
      case ISO -> exc.date();
    };
  }

  private static String renderUntil(UntilSpec until) {
    return switch (until.kind()) {
      case ISO -> until.date();
      case NAMED -> String.format("%s %d", until.month(), until.day());
    };
  }

  private static String renderMonthList(List<MonthName> months) {
    return months.stream().map(MonthName::toString).collect(Collectors.joining(", "));
  }

  private static String formatTimeList(List<TimeOfDay> times) {
    return times.stream().map(TimeOfDay::toString).collect(Collectors.joining(", "));
  }

  private static String formatDayList(List<Weekday> days) {
    return days.stream().map(Weekday::toString).collect(Collectors.joining(", "));
  }

  private static String formatOrdinalDaySpecs(List<DayOfMonthSpec> specs) {
    return specs.stream().map(Display::formatDayOfMonthSpec).collect(Collectors.joining(", "));
  }

  private static String formatDayOfMonthSpec(DayOfMonthSpec spec) {
    return switch (spec.kind()) {
      case SINGLE -> ordinalNumber(spec.day());
      case RANGE ->
          String.format("%s to %s", ordinalNumber(spec.start()), ordinalNumber(spec.end()));
    };
  }

  private static String ordinalNumber(int n) {
    return n + ordinalSuffix(n);
  }

  private static String ordinalSuffix(int n) {
    int mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 13) {
      return "th";
    }
    return switch (n % 10) {
      case 1 -> "st";
      case 2 -> "nd";
      case 3 -> "rd";
      default -> "th";
    };
  }
}
