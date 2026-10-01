import type {
  IntervalUnit,
  MonthName,
  OrdinalPosition,
  Weekday,
} from "./ast.js";
import { codePointSpan, HronError } from "./error.js";

export interface Token {
  kind: TokenKind;
  // UTF-16 offsets into the input; errors convert them to code points.
  start: number;
  end: number;
}

export type TokenKind =
  | { type: "every" }
  | { type: "on" }
  | { type: "at" }
  | { type: "from" }
  | { type: "to" }
  | { type: "in" }
  | { type: "of" }
  | { type: "the" }
  | { type: "last" }
  | { type: "except" }
  | { type: "until" }
  | { type: "starting" }
  | { type: "during" }
  | { type: "year" }
  | { type: "nearest" }
  | { type: "next" }
  | { type: "previous" }
  | { type: "day" }
  | { type: "weekday" }
  | { type: "weekend" }
  | { type: "weeks" }
  | { type: "month" }
  | { type: "dayName"; name: Weekday }
  | { type: "monthName"; name: MonthName }
  | { type: "ordinal"; name: Exclude<OrdinalPosition, "last"> }
  | { type: "intervalUnit"; unit: IntervalUnit }
  | { type: "number"; value: number }
  | { type: "ordinalNumber"; value: number }
  | { type: "time"; hour: number; minute: number }
  | { type: "isoDate" }
  | { type: "comma" }
  | { type: "timezone" };

const MAX_NUMBER = 2147483647;

export function tokenize(input: string): Token[] {
  return new Lexer(input).tokenize();
}

class Lexer {
  private input: string;
  private pos = 0;

  constructor(input: string) {
    this.input = input;
  }

  tokenize(): Token[] {
    const tokens: Token[] = [];
    while (true) {
      this.advanceWhile(isWhitespace);
      if (this.pos >= this.input.length) break;
      const start = this.pos;
      const c = this.input[start];
      let kind: TokenKind;
      if (tokens.at(-1)?.kind.type === "in") {
        this.advanceWhile((ch) => !isWhitespace(ch));
        kind = { type: "timezone" };
      } else if (c === ",") {
        this.pos++;
        kind = { type: "comma" };
      } else if (isAlpha(c)) {
        kind = this.word(start);
      } else if (isDigit(c)) {
        kind = this.digits(start);
      } else {
        throw this.unexpectedCharacter(start);
      }
      tokens.push({ kind, start, end: this.pos });
    }
    return tokens;
  }

  private advanceWhile(matches: (ch: string) => boolean): void {
    while (this.pos < this.input.length && matches(this.input[this.pos])) {
      this.pos++;
    }
  }

  private error(message: string, start: number): HronError {
    const span = codePointSpan(this.input, start, this.pos);
    return HronError.lex(message, span, this.input);
  }

  private word(start: number): TokenKind {
    this.advanceWhile((ch) => isAlpha(ch) || isDigit(ch) || ch === "_");
    const text = this.input.slice(start, this.pos);
    const kind = KEYWORDS.get(asciiLowercase(text));
    if (kind === undefined) {
      throw this.error(`unknown keyword '${text}'`, start);
    }
    return kind;
  }

  private digits(start: number): TokenKind {
    this.advanceWhile(isDigit);
    const digits = this.input.slice(start, this.pos);
    if (digits.length === 4 && this.isIsoDateTail()) {
      this.pos += "-MM-DD".length;
      return { type: "isoDate" };
    }
    if (this.input[this.pos] === ":") {
      return this.time(start);
    }
    const value = numberValue(digits);
    if (value === null) {
      throw this.error("number must be at most 2147483647", start);
    }
    const suffix = asciiLowercase(this.input.slice(this.pos, this.pos + 2));
    if (["st", "nd", "rd", "th"].includes(suffix)) {
      this.pos += 2;
      return { type: "ordinalNumber", value };
    }
    return { type: "number", value };
  }

  private isIsoDateTail(): boolean {
    const rest = this.input.slice(this.pos, this.pos + 6);
    return (
      rest.length === 6 &&
      rest[0] === "-" &&
      isDigit(rest[1]) &&
      isDigit(rest[2]) &&
      rest[3] === "-" &&
      isDigit(rest[4]) &&
      isDigit(rest[5])
    );
  }

  private time(start: number): TokenKind {
    const colon = this.pos;
    this.pos++;
    this.advanceWhile(isDigit);
    const hour = this.input.slice(start, colon);
    const minute = this.input.slice(colon + 1, this.pos);
    const text = this.input.slice(start, this.pos);
    if (hour.length > 2 || minute.length !== 2) {
      throw this.error(`time must be H:MM or HH:MM, got ${text}`, start);
    }
    const time = { hour: twoDigitValue(hour), minute: twoDigitValue(minute) };
    if (time.hour > 23 || time.minute > 59) {
      throw this.error(`time must be 00:00-23:59, got ${text}`, start);
    }
    return { type: "time", ...time };
  }

  private unexpectedCharacter(start: number): HronError {
    // For a lone surrogate codePointAt gives the surrogate itself, as the spec reports it.
    const code = this.input.codePointAt(start) as number;
    const c = String.fromCodePoint(code);
    // `'` is excluded because `'''` would not read as a quoted character.
    const shown =
      code >= 0x21 && code <= 0x7e && c !== "'"
        ? `'${c}'`
        : `U+${code.toString(16).toUpperCase().padStart(4, "0")}`;
    this.pos = start + c.length;
    return this.error(`unexpected character ${shown}`, start);
  }
}

const KEYWORDS = new Map<string, TokenKind>(
  Object.entries({
    every: { type: "every" },
    on: { type: "on" },
    at: { type: "at" },
    from: { type: "from" },
    to: { type: "to" },
    in: { type: "in" },
    of: { type: "of" },
    the: { type: "the" },
    last: { type: "last" },
    except: { type: "except" },
    until: { type: "until" },
    starting: { type: "starting" },
    during: { type: "during" },
    nearest: { type: "nearest" },
    next: { type: "next" },
    previous: { type: "previous" },

    day: { type: "day" },
    days: { type: "day" },
    weekday: { type: "weekday" },
    weekdays: { type: "weekday" },
    weekend: { type: "weekend" },
    weekends: { type: "weekend" },
    week: { type: "weeks" },
    weeks: { type: "weeks" },
    month: { type: "month" },
    months: { type: "month" },
    year: { type: "year" },
    years: { type: "year" },

    monday: { type: "dayName", name: "monday" },
    mon: { type: "dayName", name: "monday" },
    tuesday: { type: "dayName", name: "tuesday" },
    tue: { type: "dayName", name: "tuesday" },
    wednesday: { type: "dayName", name: "wednesday" },
    wed: { type: "dayName", name: "wednesday" },
    thursday: { type: "dayName", name: "thursday" },
    thu: { type: "dayName", name: "thursday" },
    friday: { type: "dayName", name: "friday" },
    fri: { type: "dayName", name: "friday" },
    saturday: { type: "dayName", name: "saturday" },
    sat: { type: "dayName", name: "saturday" },
    sunday: { type: "dayName", name: "sunday" },
    sun: { type: "dayName", name: "sunday" },

    january: { type: "monthName", name: "jan" },
    jan: { type: "monthName", name: "jan" },
    february: { type: "monthName", name: "feb" },
    feb: { type: "monthName", name: "feb" },
    march: { type: "monthName", name: "mar" },
    mar: { type: "monthName", name: "mar" },
    april: { type: "monthName", name: "apr" },
    apr: { type: "monthName", name: "apr" },
    may: { type: "monthName", name: "may" },
    june: { type: "monthName", name: "jun" },
    jun: { type: "monthName", name: "jun" },
    july: { type: "monthName", name: "jul" },
    jul: { type: "monthName", name: "jul" },
    august: { type: "monthName", name: "aug" },
    aug: { type: "monthName", name: "aug" },
    september: { type: "monthName", name: "sep" },
    sep: { type: "monthName", name: "sep" },
    october: { type: "monthName", name: "oct" },
    oct: { type: "monthName", name: "oct" },
    november: { type: "monthName", name: "nov" },
    nov: { type: "monthName", name: "nov" },
    december: { type: "monthName", name: "dec" },
    dec: { type: "monthName", name: "dec" },

    first: { type: "ordinal", name: "first" },
    second: { type: "ordinal", name: "second" },
    third: { type: "ordinal", name: "third" },
    fourth: { type: "ordinal", name: "fourth" },
    fifth: { type: "ordinal", name: "fifth" },

    min: { type: "intervalUnit", unit: "min" },
    mins: { type: "intervalUnit", unit: "min" },
    minute: { type: "intervalUnit", unit: "min" },
    minutes: { type: "intervalUnit", unit: "min" },
    hour: { type: "intervalUnit", unit: "hours" },
    hours: { type: "intervalUnit", unit: "hours" },
    hr: { type: "intervalUnit", unit: "hours" },
    hrs: { type: "intervalUnit", unit: "hours" },
  } satisfies Record<string, TokenKind>),
);

// Checked at every digit, so a run of any length cannot lose precision.
function numberValue(digits: string): number | null {
  let value = 0;
  for (const digit of digits) {
    value = value * 10 + (digit.charCodeAt(0) - 48);
    if (value > MAX_NUMBER) return null;
  }
  return value;
}

function twoDigitValue(digits: string): number {
  return numberValue(digits) as number;
}

// toLowerCase is Unicode-aware and would fold the Kelvin sign to `k`; words match in ASCII case only.
export function asciiLowercase(text: string): string {
  return text.replace(/[A-Z]/g, (ch) =>
    String.fromCharCode(ch.charCodeAt(0) + 32),
  );
}

function isDigit(ch: string): boolean {
  return ch >= "0" && ch <= "9";
}

function isAlpha(ch: string): boolean {
  return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z");
}

// Only these four separate tokens; any other whitespace is an unexpected character.
function isWhitespace(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r";
}
