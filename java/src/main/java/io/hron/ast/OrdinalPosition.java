package io.hron.ast;

import java.util.Map;
import java.util.Optional;

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

  /** 1-5, or -1 for LAST. */
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

  public static Optional<OrdinalPosition> parse(String s) {
    return Optional.ofNullable(PARSE_MAP.get(s.toLowerCase()));
  }
}
