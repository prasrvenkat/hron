package io.hron.ast;

/**
 * Represents a time of day (hour and minute).
 *
 * @param hour the hour (0-23)
 * @param minute the minute (0-59)
 */
public record TimeOfDay(int hour, int minute) {
  /**
   * Returns the time as total minutes from midnight.
   *
   * @return total minutes from midnight
   */
  public int totalMinutes() {
    return hour * 60 + minute;
  }

  @Override
  public String toString() {
    return String.format("%02d:%02d", hour, minute);
  }
}
