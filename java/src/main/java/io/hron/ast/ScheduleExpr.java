package io.hron.ast;

/**
 * Sealed interface for schedule expressions.
 *
 * <p>There are 7 types of schedule expressions:
 *
 * <ul>
 *   <li>{@link DayRepeat} - "every day at 9:00"
 *   <li>{@link IntervalRepeat} - "every 30 min from 9:00 to 17:00"
 *   <li>{@link WeekRepeat} - "every 2 weeks on monday"
 *   <li>{@link MonthRepeat} - "every month on the 1st"
 *   <li>{@link OrdinalRepeat} - "first monday of every month"
 *   <li>{@link SingleDate} - "on feb 14 at 9:00"
 *   <li>{@link YearRepeat} - "every year on dec 25"
 * </ul>
 */
public sealed interface ScheduleExpr
    permits DayRepeat,
        IntervalRepeat,
        WeekRepeat,
        MonthRepeat,
        OrdinalRepeat,
        SingleDate,
        YearRepeat {}
