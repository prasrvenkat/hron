package io.hron.ast;

/**
 * Represents which day within a year a schedule fires on.
 *
 * @param kind the type of year target
 * @param month the month
 * @param day the day (for DATE and DAY_OF_MONTH)
 * @param ordinal the ordinal position (for ORDINAL_WEEKDAY)
 * @param weekday the weekday (for ORDINAL_WEEKDAY)
 */
public record YearTarget(
    Kind kind, MonthName month, int day, OrdinalPosition ordinal, Weekday weekday) {

  public enum Kind {
    /** A specific month and day (e.g., dec 25). */
    DATE,
    /** An ordinal weekday in a month (e.g., first monday of march). */
    ORDINAL_WEEKDAY,
    /** A specific day of a month (e.g., the 15th of march). */
    DAY_OF_MONTH,
    /** The last weekday of a month. */
    LAST_WEEKDAY
  }

  public static YearTarget date(MonthName month, int day) {
    return new YearTarget(Kind.DATE, month, day, null, null);
  }

  public static YearTarget ordinalWeekday(
      OrdinalPosition ordinal, Weekday weekday, MonthName month) {
    return new YearTarget(Kind.ORDINAL_WEEKDAY, month, 0, ordinal, weekday);
  }

  public static YearTarget dayOfMonth(int day, MonthName month) {
    return new YearTarget(Kind.DAY_OF_MONTH, month, day, null, null);
  }

  public static YearTarget lastWeekday(MonthName month) {
    return new YearTarget(Kind.LAST_WEEKDAY, month, 0, null, null);
  }
}
