// Hand-rolled recursive descent parser for hron expressions.

import type {
  DateSpec,
  DayFilter,
  DayOfMonthSpec,
  Exception,
  IntervalUnit,
  MonthName,
  MonthTarget,
  OrdinalPosition,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  UntilSpec,
  Weekday,
  YearTarget,
} from "./ast.js";
import { newScheduleData, parseMonthName, parseWeekday } from "./ast.js";
import { HronError, type Span } from "./error.js";
import { type Token, type TokenKind, tokenize } from "./lexer.js";

class Parser {
  private tokens: Token[];
  private pos: number;
  private input: string;

  constructor(tokens: Token[], input: string) {
    this.tokens = tokens;
    this.pos = 0;
    this.input = input;
  }

  peek(): Token | undefined {
    return this.tokens[this.pos];
  }

  peekKind(): TokenKind | undefined {
    return this.tokens[this.pos]?.kind;
  }

  advance(): Token | undefined {
    const tok = this.tokens[this.pos];
    if (tok) this.pos++;
    return tok;
  }

  currentSpan(): Span {
    const tok = this.peek();
    if (tok) return tok.span;
    const last = this.tokens[this.tokens.length - 1];
    if (last) return { start: last.span.end, end: last.span.end };
    return { start: 0, end: 0 };
  }

  error(message: string, span: Span): HronError {
    return HronError.parse(message, span, this.input);
  }

  errorAtEnd(message: string): HronError {
    const span =
      this.tokens.length > 0
        ? {
            start: this.tokens[this.tokens.length - 1].span.end,
            end: this.tokens[this.tokens.length - 1].span.end,
          }
        : { start: 0, end: 0 };
    return HronError.parse(message, span, this.input);
  }

  consumeKind(expected: string, check: (k: TokenKind) => boolean): Token {
    const span = this.currentSpan();
    const tok = this.peek();
    if (tok && check(tok.kind)) {
      this.pos++;
      return tok;
    }
    if (tok) {
      throw this.error(`expected ${expected}, got ${tok.kind.type}`, span);
    }
    throw this.errorAtEnd(`expected ${expected}`);
  }

  // --- Grammar productions ---

  parseExpression(): ScheduleData {
    const span = this.currentSpan();
    const kind = this.peekKind();

    let expr: ScheduleExpr;
    if (kind?.type === "every") {
      this.advance();
      expr = this.parseEvery();
    } else if (kind?.type === "on") {
      this.advance();
      expr = this.parseOn();
    } else if (kind?.type === "ordinal" || kind?.type === "last") {
      expr = this.parseOrdinalRepeat();
    } else {
      throw this.error(
        "expected 'every', 'on', or an ordinal (first, second, ...)",
        span,
      );
    }

    return this.parseTrailingClauses(expr);
  }

  private parseTrailingClauses(expr: ScheduleExpr): ScheduleData {
    const schedule = newScheduleData(expr);

    // except
    if (this.peekKind()?.type === "except") {
      this.advance();
      schedule.except = this.parseExceptionList();
    }

    // until
    if (this.peekKind()?.type === "until") {
      this.advance();
      schedule.until = this.parseUntilSpec();
    }

    // starting
    if (this.peekKind()?.type === "starting") {
      this.advance();
      const k = this.peekKind();
      if (k?.type === "isoDate") {
        schedule.anchor = (k as { type: "isoDate"; date: string }).date;
        this.advance();
      } else {
        throw this.error(
          "expected ISO date (YYYY-MM-DD) after 'starting'",
          this.currentSpan(),
        );
      }
    }

    // during
    if (this.peekKind()?.type === "during") {
      this.advance();
      schedule.during = this.parseMonthList();
    }

    // in <timezone>
    if (this.peekKind()?.type === "in") {
      this.advance();
      const k = this.peekKind();
      if (k?.type === "timezone") {
        schedule.timezone = (k as { type: "timezone"; tz: string }).tz;
        this.advance();
      } else {
        throw this.error("expected timezone after 'in'", this.currentSpan());
      }
    }

    return schedule;
  }

  private parseExceptionList(): Exception[] {
    const exceptions: Exception[] = [this.parseException()];
    while (this.peekKind()?.type === "comma") {
      this.advance();
      exceptions.push(this.parseException());
    }
    return exceptions;
  }

  private parseException(): Exception {
    const k = this.peekKind();
    if (k?.type === "isoDate") {
      const date = (k as { type: "isoDate"; date: string }).date;
      this.advance();
      return { type: "iso", date };
    }
    if (k?.type === "monthName") {
      const month = parseMonthName(
        (k as { type: "monthName"; name: string }).name,
      )!;
      this.advance();
      const day = this.parseDayNumber(
        "expected day number after month name in exception",
      );
      return { type: "named", month, day };
    }
    throw this.error(
      "expected ISO date or month-day in exception",
      this.currentSpan(),
    );
  }

  private parseUntilSpec(): UntilSpec {
    const k = this.peekKind();
    if (k?.type === "isoDate") {
      const date = (k as { type: "isoDate"; date: string }).date;
      this.advance();
      return { type: "iso", date };
    }
    if (k?.type === "monthName") {
      const month = parseMonthName(
        (k as { type: "monthName"; name: string }).name,
      )!;
      this.advance();
      const day = this.parseDayNumber(
        "expected day number after month name in until",
      );
      return { type: "named", month, day };
    }
    throw this.error(
      "expected ISO date or month-day after 'until'",
      this.currentSpan(),
    );
  }

  private parseDayNumber(errorMsg: string): number {
    const k = this.peekKind();
    if (k?.type === "number") {
      const n = (k as { type: "number"; value: number }).value;
      this.advance();
      return n;
    }
    if (k?.type === "ordinalNumber") {
      const n = (k as { type: "ordinalNumber"; value: number }).value;
      this.advance();
      return n;
    }
    throw this.error(errorMsg, this.currentSpan());
  }

  // After "every": dispatch
  private parseEvery(): ScheduleExpr {
    if (!this.peek()) throw this.errorAtEnd("expected repeater");

    const k = this.peekKind()!;

    if (k.type === "year") {
      this.advance();
      return this.parseYearRepeat(1);
    }
    if (k.type === "day") {
      return this.parseDayRepeat(1, { type: "every" });
    }
    if (k.type === "weekday") {
      this.advance();
      return this.parseDayRepeat(1, { type: "weekday" });
    }
    if (k.type === "weekend") {
      this.advance();
      return this.parseDayRepeat(1, { type: "weekend" });
    }
    if (k.type === "dayName") {
      const days = this.parseDayList();
      return this.parseDayRepeat(1, { type: "days", days });
    }
    if (k.type === "month") {
      this.advance();
      return this.parseMonthRepeat(1);
    }
    if (k.type === "number") {
      return this.parseNumberRepeat();
    }

    throw this.error(
      "expected day, weekday, weekend, year, day name, month, or number after 'every'",
      this.currentSpan(),
    );
  }

  private parseDayRepeat(interval: number, days: DayFilter): ScheduleExpr {
    if (days.type === "every") {
      this.consumeKind("'day'", (k) => k.type === "day");
    }
    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();
    return { type: "dayRepeat", interval, days, times };
  }

  private parseNumberRepeat(): ScheduleExpr {
    const span = this.currentSpan();
    const k = this.peekKind()!;
    const num = (k as { type: "number"; value: number }).value;
    if (num === 0) {
      throw this.error("interval must be at least 1", span);
    }
    this.advance();

    const next = this.peekKind();
    if (next?.type === "weeks") {
      this.advance();
      return this.parseWeekRepeat(num);
    }
    if (next?.type === "intervalUnit") {
      return this.parseIntervalRepeat(num);
    }
    if (next?.type === "day") {
      return this.parseDayRepeat(num, { type: "every" });
    }
    if (next?.type === "month") {
      this.advance();
      return this.parseMonthRepeat(num);
    }
    if (next?.type === "year") {
      this.advance();
      return this.parseYearRepeat(num);
    }

    throw this.error(
      "expected 'weeks', 'min', 'minutes', 'hour', 'hours', 'day(s)', 'month(s)', or 'year(s)' after number",
      this.currentSpan(),
    );
  }

  private parseIntervalRepeat(interval: number): ScheduleExpr {
    const k = this.peekKind()!;
    const unitStr = (k as { type: "intervalUnit"; unit: string }).unit;
    this.advance();

    const unit: IntervalUnit = unitStr === "min" ? "min" : "hours";

    this.consumeKind("'from'", (k) => k.type === "from");
    const from = this.parseTime();
    this.consumeKind("'to'", (k) => k.type === "to");
    const to = this.parseTime();

    let dayFilter: DayFilter | null = null;
    if (this.peekKind()?.type === "on") {
      this.advance();
      dayFilter = this.parseDayTarget();
    }

    return { type: "intervalRepeat", interval, unit, from, to, dayFilter };
  }

  private parseWeekRepeat(interval: number): ScheduleExpr {
    this.consumeKind("'on'", (k) => k.type === "on");
    const days = this.parseDayList();
    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();
    return { type: "weekRepeat", interval, days, times };
  }

  private parseMonthRepeat(interval: number): ScheduleExpr {
    this.consumeKind("'on'", (k) => k.type === "on");
    this.consumeKind("'the'", (k) => k.type === "the");

    let target: MonthTarget;
    const k = this.peekKind();

    if (k?.type === "last") {
      this.advance();
      const next = this.peekKind();
      if (next?.type === "day") {
        this.advance();
        target = { type: "lastDay" };
      } else if (next?.type === "weekday") {
        this.advance();
        target = { type: "lastWeekday" };
      } else {
        throw this.error(
          "expected 'day' or 'weekday' after 'last'",
          this.currentSpan(),
        );
      }
    } else if (k?.type === "ordinalNumber") {
      const specs = this.parseOrdinalDayList();
      target = { type: "days", specs };
    } else {
      throw this.error(
        "expected ordinal day (1st, 15th) or 'last' after 'the'",
        this.currentSpan(),
      );
    }

    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();
    return { type: "monthRepeat", interval, target, times };
  }

  private parseOrdinalRepeat(): ScheduleExpr {
    const ordinal = this.parseOrdinalPosition();

    const k = this.peekKind();
    if (k?.type !== "dayName") {
      throw this.error("expected day name after ordinal", this.currentSpan());
    }
    const day = parseWeekday(
      (k as { type: "dayName"; name: string }).name,
    )! as Weekday;
    this.advance();

    this.consumeKind("'of'", (k) => k.type === "of");
    this.consumeKind("'every'", (k) => k.type === "every");

    // "of every [N] month(s) at ..."
    let interval = 1;
    const next = this.peekKind();
    if (next?.type === "number") {
      interval = (next as { type: "number"; value: number }).value;
      if (interval === 0) {
        throw this.error("interval must be at least 1", this.currentSpan());
      }
      this.advance();
    }

    this.consumeKind("'month'", (k) => k.type === "month");
    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();

    return { type: "ordinalRepeat", interval, ordinal, day, times };
  }

  private parseYearRepeat(interval: number): ScheduleExpr {
    this.consumeKind("'on'", (k) => k.type === "on");

    let target: YearTarget;
    const k = this.peekKind();

    if (k?.type === "the") {
      this.advance();
      target = this.parseYearTargetAfterThe();
    } else if (k?.type === "monthName") {
      const month = parseMonthName(
        (k as { type: "monthName"; name: string }).name,
      )!;
      this.advance();
      const day = this.parseDayNumber("expected day number after month name");
      target = { type: "date", month, day };
    } else {
      throw this.error(
        "expected month name or 'the' after 'every year on'",
        this.currentSpan(),
      );
    }

    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();
    return { type: "yearRepeat", interval, target, times };
  }

  private parseYearTargetAfterThe(): YearTarget {
    const k = this.peekKind();

    if (k?.type === "last") {
      this.advance();
      const next = this.peekKind();
      if (next?.type === "weekday") {
        this.advance();
        this.consumeKind("'of'", (k) => k.type === "of");
        const month = this.parseMonthNameToken();
        return { type: "lastWeekday", month };
      }
      if (next?.type === "dayName") {
        const weekday = parseWeekday(
          (next as { type: "dayName"; name: string }).name,
        )! as Weekday;
        this.advance();
        this.consumeKind("'of'", (k) => k.type === "of");
        const month = this.parseMonthNameToken();
        return { type: "ordinalWeekday", ordinal: "last", weekday, month };
      }
      throw this.error(
        "expected 'weekday' or day name after 'last' in yearly expression",
        this.currentSpan(),
      );
    }

    if (k?.type === "ordinal") {
      const ordinal = this.parseOrdinalPosition();
      const next = this.peekKind();
      if (next?.type === "dayName") {
        const weekday = parseWeekday(
          (next as { type: "dayName"; name: string }).name,
        )! as Weekday;
        this.advance();
        this.consumeKind("'of'", (k) => k.type === "of");
        const month = this.parseMonthNameToken();
        return { type: "ordinalWeekday", ordinal, weekday, month };
      }
      throw this.error(
        "expected day name after ordinal in yearly expression",
        this.currentSpan(),
      );
    }

    if (k?.type === "ordinalNumber") {
      const day = (k as { type: "ordinalNumber"; value: number }).value;
      this.advance();
      this.consumeKind("'of'", (k) => k.type === "of");
      const month = this.parseMonthNameToken();
      return { type: "dayOfMonth", day, month };
    }

    throw this.error(
      "expected ordinal, day number, or 'last' after 'the' in yearly expression",
      this.currentSpan(),
    );
  }

  private parseMonthNameToken(): MonthName {
    const k = this.peekKind();
    if (k?.type === "monthName") {
      const month = parseMonthName(
        (k as { type: "monthName"; name: string }).name,
      )!;
      this.advance();
      return month;
    }
    throw this.error("expected month name", this.currentSpan());
  }

  private parseOrdinalPosition(): OrdinalPosition {
    const span = this.currentSpan();
    const k = this.peekKind();

    if (k?.type === "ordinal") {
      const name = (k as { type: "ordinal"; name: string }).name;
      this.advance();
      return name as OrdinalPosition;
    }
    if (k?.type === "last") {
      this.advance();
      return "last";
    }
    throw this.error(
      "expected ordinal (first, second, third, fourth, fifth, last)",
      span,
    );
  }

  private parseOn(): ScheduleExpr {
    const date = this.parseDateTarget();
    this.consumeKind("'at'", (k) => k.type === "at");
    const times = this.parseTimeList();
    return { type: "singleDate", date, times };
  }

  private parseDateTarget(): DateSpec {
    const k = this.peekKind();

    if (k?.type === "isoDate") {
      const date = (k as { type: "isoDate"; date: string }).date;
      this.advance();
      return { type: "iso", date };
    }
    if (k?.type === "monthName") {
      const month = parseMonthName(
        (k as { type: "monthName"; name: string }).name,
      )!;
      this.advance();
      const day = this.parseDayNumber("expected day number after month name");
      return { type: "named", month, day };
    }
    throw this.error(
      "expected date (ISO date or month name)",
      this.currentSpan(),
    );
  }

  private parseDayTarget(): DayFilter {
    const k = this.peekKind();
    if (k?.type === "day") {
      this.advance();
      return { type: "every" };
    }
    if (k?.type === "weekday") {
      this.advance();
      return { type: "weekday" };
    }
    if (k?.type === "weekend") {
      this.advance();
      return { type: "weekend" };
    }
    if (k?.type === "dayName") {
      const days = this.parseDayList();
      return { type: "days", days };
    }
    throw this.error(
      "expected 'day', 'weekday', 'weekend', or day name",
      this.currentSpan(),
    );
  }

  private parseDayList(): Weekday[] {
    const k = this.peekKind();
    if (k?.type !== "dayName") {
      throw this.error("expected day name", this.currentSpan());
    }
    const days: Weekday[] = [
      parseWeekday((k as { type: "dayName"; name: string }).name)! as Weekday,
    ];
    this.advance();

    while (this.peekKind()?.type === "comma") {
      this.advance();
      const next = this.peekKind();
      if (next?.type !== "dayName") {
        throw this.error("expected day name after ','", this.currentSpan());
      }
      days.push(
        parseWeekday(
          (next as { type: "dayName"; name: string }).name,
        )! as Weekday,
      );
      this.advance();
    }
    return days;
  }

  private parseOrdinalDayList(): DayOfMonthSpec[] {
    const specs: DayOfMonthSpec[] = [this.parseOrdinalDaySpec()];
    while (this.peekKind()?.type === "comma") {
      this.advance();
      specs.push(this.parseOrdinalDaySpec());
    }
    return specs;
  }

  private parseOrdinalDaySpec(): DayOfMonthSpec {
    const k = this.peekKind();
    if (k?.type !== "ordinalNumber") {
      throw this.error("expected ordinal day number", this.currentSpan());
    }
    const start = (k as { type: "ordinalNumber"; value: number }).value;
    this.advance();

    if (this.peekKind()?.type === "to") {
      this.advance();
      const next = this.peekKind();
      if (next?.type !== "ordinalNumber") {
        throw this.error(
          "expected ordinal day number after 'to'",
          this.currentSpan(),
        );
      }
      const end = (next as { type: "ordinalNumber"; value: number }).value;
      this.advance();
      return { type: "range", start, end };
    }

    return { type: "single", day: start };
  }

  private parseMonthList(): MonthName[] {
    const months: MonthName[] = [this.parseMonthNameToken()];
    while (this.peekKind()?.type === "comma") {
      this.advance();
      months.push(this.parseMonthNameToken());
    }
    return months;
  }

  private parseTimeList(): TimeOfDay[] {
    const times: TimeOfDay[] = [this.parseTime()];
    while (this.peekKind()?.type === "comma") {
      this.advance();
      times.push(this.parseTime());
    }
    return times;
  }

  private parseTime(): TimeOfDay {
    const span = this.currentSpan();
    const k = this.peekKind();
    if (k?.type === "time") {
      const { hour, minute } = k as {
        type: "time";
        hour: number;
        minute: number;
      };
      this.advance();
      return { hour, minute };
    }
    throw this.error("expected time (HH:MM)", span);
  }
}

/** Parse an hron expression string into a ScheduleData AST. */
export function parse(input: string): ScheduleData {
  const tokens = tokenize(input);

  if (tokens.length === 0) {
    throw HronError.parse("empty expression", { start: 0, end: 0 }, input);
  }

  const parser = new Parser(tokens, input);
  const schedule = parser.parseExpression();

  if (parser.peek()) {
    throw HronError.parse(
      "unexpected tokens after expression",
      parser.currentSpan(),
      input,
    );
  }

  return schedule;
}
