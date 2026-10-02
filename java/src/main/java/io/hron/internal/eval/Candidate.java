package io.hron.internal.eval;

import io.hron.ast.DateSpec;
import io.hron.ast.DayRepeat;
import io.hron.ast.IntervalRepeat;
import io.hron.ast.MonthRepeat;
import io.hron.ast.MonthTarget;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.SingleDate;
import io.hron.ast.WeekRepeat;
import io.hron.ast.Weekday;
import io.hron.ast.YearRepeat;
import java.time.LocalDate;
import java.time.Month;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * A date the expression fires on, with the month whose day it names. They differ only when a
 * directional nearest weekday crosses into the adjacent month.
 */
record Candidate(LocalDate date, Month targetMonth) {
  static List<Candidate> candidatesInPeriod(ScheduleExpr expr, LocalDate start) {
    return switch (expr) {
      case IntervalRepeat ir ->
          ir.dayFilter() == null || CalendarDates.matchesDayFilter(start, ir.dayFilter())
              ? List.of(on(start))
              : List.of();
      case DayRepeat dr ->
          CalendarDates.matchesDayFilter(start, dr.days()) ? List.of(on(start)) : List.of();
      case WeekRepeat wr -> weekCandidates(wr.weekDays(), start);
      case MonthRepeat mr -> monthCandidates(mr.target(), start);
      case YearRepeat yr -> onIfPresent(CalendarDates.yearTargetDate(start.getYear(), yr.target()));
      case SingleDate sd ->
          switch (sd.dateSpec().kind()) {
            case NAMED -> {
              DateSpec named = sd.dateSpec();
              yield onIfPresent(
                  CalendarDates.dateOf(start.getYear(), named.month().number(), named.day()));
            }
            case ISO -> List.of(on(start));
          };
    };
  }

  private static List<Candidate> weekCandidates(List<Weekday> days, LocalDate monday) {
    List<Candidate> candidates = new ArrayList<>(days.size());
    for (Weekday day : Weekday.values()) {
      if (days.contains(day)) {
        candidates.add(on(monday.plusDays(day.number() - 1)));
      }
    }
    return candidates;
  }

  private static List<Candidate> monthCandidates(MonthTarget target, LocalDate start) {
    List<LocalDate> dates = CalendarDates.monthTargetDates(YearMonth.from(start), target);
    List<Candidate> candidates = new ArrayList<>(dates.size());
    for (LocalDate date : dates) {
      candidates.add(new Candidate(date, start.getMonth()));
    }
    return candidates;
  }

  private static Candidate on(LocalDate date) {
    return new Candidate(date, date.getMonth());
  }

  private static List<Candidate> onIfPresent(Optional<LocalDate> date) {
    return date.isPresent() ? List.of(on(date.get())) : List.of();
  }
}
