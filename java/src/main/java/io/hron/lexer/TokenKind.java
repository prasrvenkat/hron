package io.hron.lexer;

/** The type of token. */
public enum TokenKind {
  // Keywords
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

  // Value-carrying tokens
  DAY_NAME,
  MONTH_NAME,
  ORDINAL,
  INTERVAL_UNIT,
  NUMBER,
  ORDINAL_NUMBER,
  TIME,
  ISO_DATE,
  COMMA,
  TIMEZONE
}
