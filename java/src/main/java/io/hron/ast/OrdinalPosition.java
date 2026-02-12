package io.hron.ast;

import java.util.Map;
import java.util.Optional;

/** Represents an ordinal position (first, second, etc.). */
public enum OrdinalPosition {
  FIRST(1, "first"),
  SECOND(2, "second"),
  THIRD(3, "third"),
  FOURTH(4, "fourth"),
  FIFTH(5, "fifth"),
  LAST(-1, "last");

  private final int number;
  private final String displayName;

  OrdinalPosition(int number, String displayName) {
    this.number = number;
    this.displayName = displayName;
  }

  /**
   * Returns the ordinal as a number (1-5, or -1 for Last).
   *
   * @return the ordinal number
   */
  public int toN() {
    return number;
  }

  @Override
  public String toString() {
    return displayName;
  }

  private static final Map<String, OrdinalPosition> PARSE_MAP =
      Map.of(
          "first", FIRST,
          "second", SECOND,
          "third", THIRD,
          "fourth", FOURTH,
          "fifth", FIFTH,
          "last", LAST);

  /**
   * Parses an ordinal position name (case insensitive).
   *
   * @param s the string to parse
   * @return the ordinal position if valid
   */
  public static Optional<OrdinalPosition> parse(String s) {
    return Optional.ofNullable(PARSE_MAP.get(s.toLowerCase()));
  }
}
