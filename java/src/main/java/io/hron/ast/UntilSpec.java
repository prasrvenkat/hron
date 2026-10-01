package io.hron.ast;

public record UntilSpec(Kind kind, String date, MonthName month, int day) {

  public enum Kind {
    ISO,
    NAMED
  }

  public static UntilSpec iso(String date) {
    return new UntilSpec(Kind.ISO, date, null, 0);
  }

  public static UntilSpec named(MonthName month, int day) {
    return new UntilSpec(Kind.NAMED, null, month, day);
  }
}
