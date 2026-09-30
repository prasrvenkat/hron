package io.hron.ast;

/**
 * An expression that fires every N minutes or hours within a daily window.
 *
 * @param interval the interval value
 * @param unit the interval unit (minutes or hours)
 * @param fromTime the start time of the daily window
 * @param toTime the end time of the daily window
 * @param dayFilter the days the window applies on, or null for every day
 */
public record IntervalRepeat(
    int interval, IntervalUnit unit, TimeOfDay fromTime, TimeOfDay toTime, DayFilter dayFilter)
    implements ScheduleExpr {}
