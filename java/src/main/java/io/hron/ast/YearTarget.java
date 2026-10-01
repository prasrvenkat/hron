package io.hron.ast;

public record YearTarget(
    Kind kind, MonthName month, int day, OrdinalPosition ordinal, Weekday weekday) {

  public enum Kind {
    DATE,
    ORDINAL_WEEKDAY,
    DAY_OF_MONTH,
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
