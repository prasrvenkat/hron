package io.hron.lexer;

/** The type of token. */
public enum TokenKind {
  // Keywords
  /** The "every" keyword. */
  EVERY,
  /** The "on" keyword. */
  ON,
  /** The "at" keyword. */
  AT,
  /** The "from" keyword. */
  FROM,
  /** The "to" keyword. */
  TO,
  /** The "in" keyword. */
  IN,
  /** The "of" keyword. */
  OF,
  /** The "the" keyword. */
  THE,
  /** The "last" keyword. */
  LAST,
  /** The "except" keyword. */
  EXCEPT,
  /** The "until" keyword. */
  UNTIL,
  /** The "starting" keyword. */
  STARTING,
  /** The "during" keyword. */
  DURING,
  /** The "year" keyword. */
  YEAR,
  /** The "day" keyword. */
  DAY,
  /** The "weekday" keyword. */
  WEEKDAY,
  /** The "weekend" keyword. */
  WEEKEND,
  /** The "weeks" keyword. */
  WEEKS,
  /** The "month" keyword. */
  MONTH,
  /** The "nearest" keyword. */
  NEAREST,
  /** The "next" keyword. */
  NEXT,
  /** The "previous" keyword. */
  PREVIOUS,

  // Value-carrying tokens
  /** A day-of-week name (e.g., "monday"). */
  DAY_NAME,
  /** A month name (e.g., "jan"). */
  MONTH_NAME,
  /** An ordinal position (e.g., "first"). */
  ORDINAL,
  /** An interval unit (e.g., "min", "hours"). */
  INTERVAL_UNIT,
  /** A numeric literal. */
  NUMBER,
  /** An ordinal number (e.g., "1st", "15th"). */
  ORDINAL_NUMBER,
  /** A time literal (e.g., "09:00"). */
  TIME,
  /** An ISO date (e.g., "2024-01-15"). */
  ISO_DATE,
  /** A comma separator. */
  COMMA,
  /** A timezone identifier. */
  TIMEZONE
}
