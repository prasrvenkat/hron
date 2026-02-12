package io.hron.ast;

/**
 * An interval-based repeat expression like "every 30 min from 09:00 to 17:00".
 *
 * @param interval the interval value
 * @param unit the interval unit (minutes or hours)
 * @param fromTime the start time of the daily window
 * @param toTime the end time of the daily window
 * @param dayFilter optional day filter to restrict which days apply
 */
public record IntervalRepeat(
    int interval, IntervalUnit unit, TimeOfDay fromTime, TimeOfDay toTime, DayFilter dayFilter)
    implements ScheduleExpr {}
