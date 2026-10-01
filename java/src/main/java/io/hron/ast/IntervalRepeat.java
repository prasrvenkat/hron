package io.hron.ast;

public record IntervalRepeat(
    int interval, IntervalUnit unit, TimeOfDay fromTime, TimeOfDay toTime, DayFilter dayFilter)
    implements ScheduleExpr {}
