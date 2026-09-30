package io.hron.lexer;

/** The type of token. */
public enum TokenKind {
  EVERY,
  ON,
  AT,
  FROM,
  TO,
  IN,
  OF,
  THE,
  LAST,
  EXCEPT,
  UNTIL,
  STARTING,
  DURING,
  YEAR,
  DAY,
  WEEKDAY,
  WEEKEND,
  WEEKS,
  MONTH,
  NEAREST,
  NEXT,
  PREVIOUS,

  DAY_NAME,
  MONTH_NAME,
  /** An ordinal position (e.g., "first"). */
  ORDINAL,
  INTERVAL_UNIT,
  NUMBER,
  /** An ordinal number (e.g., "1st", "15th"). */
  ORDINAL_NUMBER,
  TIME,
  ISO_DATE,
  COMMA,
  TIMEZONE
}
