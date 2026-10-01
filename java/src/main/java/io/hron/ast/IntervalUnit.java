package io.hron.ast;

public enum IntervalUnit {
  MINUTES("min"),
  HOURS("hours");

  private final String displayName;

  IntervalUnit(String displayName) {
    this.displayName = displayName;
  }

  @Override
  public String toString() {
    return displayName;
  }

  public String display(int interval) {
    return switch (this) {
      case MINUTES -> interval == 1 ? "minute" : "min";
      case HOURS -> interval == 1 ? "hour" : "hours";
    };
  }
}
