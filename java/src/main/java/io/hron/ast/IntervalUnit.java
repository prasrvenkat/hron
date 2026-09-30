package io.hron.ast;

/** Represents the unit of an interval (minutes or hours). */
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

  /**
   * Returns the unit as displayed after {@code interval}, singular when it is 1.
   *
   * @param interval the interval value
   * @return the display string
   */
  public String display(int interval) {
    return switch (this) {
      case MINUTES -> interval == 1 ? "minute" : "min";
      case HOURS -> interval == 1 ? "hour" : "hours";
    };
  }
}
