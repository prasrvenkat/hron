package io.hron.ast;

/** The expression part of a schedule, before any trailing clauses. */
public sealed interface ScheduleExpr
    permits DayRepeat, IntervalRepeat, WeekRepeat, MonthRepeat, SingleDate, YearRepeat {}
