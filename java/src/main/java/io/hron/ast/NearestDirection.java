package io.hron.ast;

/** Direction for nearest weekday (hron extension beyond cron W). */
public enum NearestDirection {
  /** Always prefer following weekday (can cross to next month). */
  NEXT,
  /** Always prefer preceding weekday (can cross to prev month). */
  PREVIOUS
}
