package io.hron.ast;

public record DateSpec(Kind kind, MonthName month, int day, String date) {

  public enum Kind {
    NAMED,
    ISO
  }

  public static DateSpec named(MonthName month, int day) {
    return new DateSpec(Kind.NAMED, month, day, null);
  }

  public static DateSpec iso(String date) {
    return new DateSpec(Kind.ISO, null, 0, date);
  }
}
