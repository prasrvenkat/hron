package io.hron;

/**
 * The part of the input an error points at, counted in Unicode code points, not UTF-16 units.
 *
 * @param start the first code point (inclusive)
 * @param end the code point after the last (exclusive)
 */
public record Span(int start, int end) {
  /**
   * Returns the length of this span.
   *
   * @return {@code end - start}, but at least 1 so an empty span still gets one caret
   */
  public int length() {
    return Math.max(1, end - start);
  }
}
