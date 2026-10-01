package io.hron.ast;

public record TimeOfDay(int hour, int minute) {
  public int totalMinutes() {
    return hour * 60 + minute;
  }

  @Override
  public String toString() {
    return String.format("%02d:%02d", hour, minute);
  }
}
