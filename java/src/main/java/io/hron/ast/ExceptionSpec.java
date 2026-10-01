package io.hron.ast;

public record ExceptionSpec(Kind kind, MonthName month, int day, String date) {

  public enum Kind {
    NAMED,
    ISO
  }

  public static ExceptionSpec named(MonthName month, int day) {
    return new ExceptionSpec(Kind.NAMED, month, day, null);
  }

  public static ExceptionSpec iso(String date) {
    return new ExceptionSpec(Kind.ISO, null, 0, date);
  }
}
