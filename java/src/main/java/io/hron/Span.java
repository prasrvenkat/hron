package io.hron;

/**
 * Represents a range of character positions in the input.
 *
 * @param start the start position (inclusive)
 * @param end the end position (exclusive)
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
