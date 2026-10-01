package io.hron.ast;

public sealed interface ScheduleExpr
    permits DayRepeat, IntervalRepeat, WeekRepeat, MonthRepeat, SingleDate, YearRepeat {}
