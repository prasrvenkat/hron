import { HronError, type Span } from "./error.js";

export interface Token {
  kind: TokenKind;
  span: Span;
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
  | { type: "day" }
  | { type: "weekday" }
  | { type: "weekend" }
  | { type: "weeks" }
  | { type: "month" }
  | { type: "dayName"; name: string }
  | { type: "monthName"; name: string }
  | { type: "ordinal"; name: string }
  | { type: "intervalUnit"; unit: string }

  | { type: "number"; value: number }
  | { type: "ordinalNumber"; value: number }
  | { type: "time"; hour: number; minute: number }
  | { type: "isoDate"; date: string }
  | { type: "comma" }
  | { type: "timezone"; tz: string };

export function tokenize(input: string): Token[] {
  const lexer = new Lexer(input);
  return lexer.tokenize();
}

class Lexer {
  private input: string;
  private pos: number;
  private afterIn: boolean;

  constructor(input: string) {
    this.input = input;
    this.pos = 0;
    this.afterIn = false;
  }

  tokenize(): Token[] {
    const tokens: Token[] = [];
    while (true) {
      this.skipWhitespace();
      if (this.pos >= this.input.length) break;

      if (this.afterIn) {
        this.afterIn = false;
        tokens.push(this.lexTimezone());
        continue;
      }

      const start = this.pos;
      const ch = this.input[this.pos];

      if (ch === ",") {
        this.pos++;
        tokens.push({ kind: { type: "comma" }, span: { start, end: this.pos } });
        continue;
      }

      if (isDigit(ch)) {
        tokens.push(this.lexNumberOrTimeOrDate());
        continue;
      }

      if (isAlpha(ch)) {
        tokens.push(this.lexWord());
        continue;
      }

      throw HronError.lex(
        `unexpected character '${ch}'`,
        { start, end: start + 1 },
        this.input,
      );
    }
    return tokens;
  }

  private skipWhitespace(): void {
    while (this.pos < this.input.length && isWhitespace(this.input[this.pos])) {
      this.pos++;
    }
  }

  private lexTimezone(): Token {
    this.skipWhitespace();
    const start = this.pos;
    while (
      this.pos < this.input.length &&
      !isWhitespace(this.input[this.pos])
    ) {
      this.pos++;
    }
    const tz = this.input.slice(start, this.pos);
    if (tz.length === 0) {
      throw HronError.lex(
        "expected timezone after 'in'",
        { start, end: start + 1 },
        this.input,
      );
    }
    return { kind: { type: "timezone", tz }, span: { start, end: this.pos } };
  }

  private lexNumberOrTimeOrDate(): Token {
    const start = this.pos;
    const numStart = this.pos;
    while (this.pos < this.input.length && isDigit(this.input[this.pos])) {
      this.pos++;
    }
    const digits = this.input.slice(numStart, this.pos);

    // Check for ISO date: YYYY-MM-DD
    if (
      digits.length === 4 &&
      this.pos < this.input.length &&
      this.input[this.pos] === "-"
    ) {
      const remaining = this.input.slice(start);
      if (
        remaining.length >= 10 &&
        remaining[4] === "-" &&
        isDigit(remaining[5]) &&
        isDigit(remaining[6]) &&
        remaining[7] === "-" &&
        isDigit(remaining[8]) &&
        isDigit(remaining[9])
      ) {
        this.pos = start + 10;
        return {
          kind: { type: "isoDate", date: this.input.slice(start, this.pos) },
          span: { start, end: this.pos },
        };
      }
    }

    // Check for time: HH:MM
    if (
      (digits.length === 1 || digits.length === 2) &&
      this.pos < this.input.length &&
      this.input[this.pos] === ":"
    ) {
      this.pos++; // skip ':'
      const minStart = this.pos;
      while (this.pos < this.input.length && isDigit(this.input[this.pos])) {
        this.pos++;
      }
      const minDigits = this.input.slice(minStart, this.pos);
      if (minDigits.length === 2) {
        const hour = parseInt(digits, 10);
        const minute = parseInt(minDigits, 10);
        if (hour > 23 || minute > 59) {
          throw HronError.lex(
            "invalid time",
            { start, end: this.pos },
            this.input,
          );
        }
        return {
          kind: { type: "time", hour, minute },
          span: { start, end: this.pos },
        };
      }
    }

    const num = parseInt(digits, 10);
    if (isNaN(num)) {
      throw HronError.lex(
        "invalid number",
        { start, end: this.pos },
        this.input,
      );
    }

    // Check for ordinal suffix: st, nd, rd, th
    if (this.pos + 1 < this.input.length) {
      const suffix = this.input.slice(this.pos, this.pos + 2).toLowerCase();
      if (suffix === "st" || suffix === "nd" || suffix === "rd" || suffix === "th") {
        this.pos += 2;
        return {
          kind: { type: "ordinalNumber", value: num },
          span: { start, end: this.pos },
        };
      }
    }

    return {
      kind: { type: "number", value: num },
      span: { start, end: this.pos },
    };
  }

  private lexWord(): Token {
    const start = this.pos;
    while (
      this.pos < this.input.length &&
      (isAlphanumeric(this.input[this.pos]) || this.input[this.pos] === "_")
    ) {
      this.pos++;
    }
    const word = this.input.slice(start, this.pos).toLowerCase();
    const span = { start, end: this.pos };

    const kind = KEYWORD_MAP[word];
    if (kind === undefined) {
      throw HronError.lex(`unknown keyword '${word}'`, span, this.input);
    }

    if (kind.type === "in") {
      this.afterIn = true;
    }

    return { kind, span };
  }
}

const KEYWORD_MAP: Record<string, TokenKind> = {
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
  year: { type: "year" },

  day: { type: "day" },
  weekday: { type: "weekday" },
  weekdays: { type: "weekday" },
  weekend: { type: "weekend" },
  weekends: { type: "weekend" },
  weeks: { type: "weeks" },
  week: { type: "weeks" },
  month: { type: "month" },

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
};

function isDigit(ch: string): boolean {
  return ch >= "0" && ch <= "9";
}

function isAlpha(ch: string): boolean {
  return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z");
}

function isAlphanumeric(ch: string): boolean {
  return isDigit(ch) || isAlpha(ch);
}

function isWhitespace(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r";
}
