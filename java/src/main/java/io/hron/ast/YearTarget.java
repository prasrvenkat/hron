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

  /** The type of year target. */
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

  /**
   * Creates a year target for a specific month and day.
   *
   * @param month the month
   * @param day the day
   * @return a new date target
   */
  public static YearTarget date(MonthName month, int day) {
    return new YearTarget(Kind.DATE, month, day, null, null);
  }

  /**
   * Creates a year target for an ordinal weekday in a month.
   *
   * @param ordinal the ordinal position
   * @param weekday the weekday
   * @param month the month
   * @return a new ordinal weekday target
   */
  public static YearTarget ordinalWeekday(
      OrdinalPosition ordinal, Weekday weekday, MonthName month) {
    return new YearTarget(Kind.ORDINAL_WEEKDAY, month, 0, ordinal, weekday);
  }

  /**
   * Creates a year target for a specific day of a month.
   *
   * @param day the day
   * @param month the month
   * @return a new day-of-month target
   */
  public static YearTarget dayOfMonth(int day, MonthName month) {
    return new YearTarget(Kind.DAY_OF_MONTH, month, day, null, null);
  }

  /**
   * Creates a year target for the last weekday of a month.
   *
   * @param month the month
   * @return a new last-weekday target
   */
  public static YearTarget lastWeekday(MonthName month) {
    return new YearTarget(Kind.LAST_WEEKDAY, month, 0, null, null);
  }
}
