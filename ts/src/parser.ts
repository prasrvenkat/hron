import { Temporal } from "@js-temporal/polyfill";
import type {
  DateSpec,
  DayFilter,
  DayOfMonthSpec,
  IntervalUnit,
  MonthName,
  MonthTarget,
  NearestDirection,
  ScheduleData,
  ScheduleExpr,
  TimeOfDay,
  UntilSpec,
  Weekday,
  YearTarget,
} from "./ast.js";
import { codePointSpan, HronError } from "./error.js";
import {
  asciiLowercase,
  type Token,
  type TokenKind,
  tokenize,
} from "./lexer.js";

// The `{what}` of each `expected {what}, got ...` error, one per phrase in
// the position table of spec/README.md, "Parse errors".
const EXPECTED = {
  everyOrOn: "'every' or 'on'",
  repeater:
    "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
  unit: "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')",
  at: "'at'",
  time: "a time (HH:MM)",
  from: "'from'",
  to: "'to'",
  dayTarget: "'day', 'weekday', 'weekend' or a day name",
  on: "'on'",
  dayName: "a day name",
  the: "'the'",
  monthTarget:
    "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
  monthLast: "'day', 'weekday' or a day name",
  nearest: "'nearest'",
  weekday: "'weekday'",
  dayOfMonth: "a day such as 15th",
  yearTarget: "a month name or 'the'",
  yearThe: "a day such as 15th, 'last' or an ordinal such as 'first'",
  yearLast: "'weekday' or a day name",
  of: "'of'",
  monthName: "a month name",
  dayNumber: "a day number",
  date: "a date (YYYY-MM-DD, or a month and day)",
  isoDate: "a date (YYYY-MM-DD)",
  timezone: "a timezone",
} as const;

const CLAUSE_ORDER = ["except", "until", "starting", "during", "in"] as const;

const MONTH_LENGTHS: Record<MonthName, number> = {
  jan: 31,
  feb: 29,
  mar: 31,
  apr: 30,
  may: 31,
  jun: 30,
  jul: 31,
  aug: 31,
  sep: 30,
  oct: 31,
  nov: 30,
  dec: 31,
};

type KindOf<T extends TokenKind["type"]> = Extract<TokenKind, { type: T }>;

class Parser {
  private tokens: Token[];
  private input: string;
  private pos = 0;
  private untilRange: [number, number] | null = null;

  constructor(tokens: Token[], input: string) {
    this.tokens = tokens;
    this.input = input;
  }

  peek(): Token | undefined {
    return this.tokens[this.pos];
  }

  private peekKind(): TokenKind | undefined {
    return this.tokens[this.pos]?.kind;
  }

  private peekIs<T extends TokenKind["type"]>(type: T): KindOf<T> | undefined {
    const kind = this.peekKind();
    return kind?.type === type ? (kind as KindOf<T>) : undefined;
  }

  private advance(): Token {
    return this.tokens[this.pos++];
  }

  private previous(): Token {
    return this.tokens[this.pos - 1];
  }

  private eat(type: TokenKind["type"]): boolean {
    const found = this.peekKind()?.type === type;
    if (found) this.pos++;
    return found;
  }

  private expect(type: TokenKind["type"], what: string): void {
    if (!this.eat(type)) throw this.expected(what);
  }

  private text(token: Token): string {
    return this.input.slice(token.start, token.end);
  }

  private error(message: string, start: number, end: number): HronError {
    const span = codePointSpan(this.input, start, end);
    return HronError.parse(message, span, this.input);
  }

  private expected(what: string): HronError {
    const token = this.peek();
    if (token !== undefined) {
      return this.error(
        `expected ${what}, got '${this.text(token)}'`,
        token.start,
        token.end,
      );
    }
    const end = this.tokens.at(-1)?.end ?? 0;
    return this.error(`expected ${what}, got end of input`, end, end);
  }

  parseExpression(): ScheduleExpr {
    if (this.eat("every")) return this.parseEvery();
    if (this.eat("on")) return this.parseOn();
    throw this.expected(EXPECTED.everyOrOn);
  }

  parseClauses(expr: ScheduleExpr): ScheduleData {
    const except = this.eat("except") ? this.parseDateList() : [];

    let until: UntilSpec | null = null;
    if (this.peekIs("until")) {
      const token = this.advance();
      until = this.parseDate();
      this.untilRange = [token.start, this.previous().end];
    }

    let anchor: string | null = null;
    if (this.eat("starting")) {
      if (!this.peekIs("isoDate")) throw this.expected(EXPECTED.isoDate);
      anchor = this.isoDate(this.advance());
    }

    const during = this.eat("during") ? this.parseMonthList() : [];

    let timezone: string | null = null;
    if (this.eat("in")) {
      if (!this.peekIs("timezone")) throw this.expected(EXPECTED.timezone);
      timezone = this.timezone(this.advance());
    }

    return { expr, timezone, except, until, anchor, during };
  }

  leftover(schedule: ScheduleData): HronError {
    const token = this.tokens[this.pos];
    // Every clause holds at least one item, so a clause was read exactly when its field is set.
    const read = [
      schedule.except.length > 0,
      schedule.until !== null,
      schedule.anchor !== null,
      schedule.during.length > 0,
      schedule.timezone !== null,
    ];
    const clause = CLAUSE_ORDER.indexOf(
      token.kind.type as (typeof CLAUSE_ORDER)[number],
    );
    const lastRead = read.lastIndexOf(true);
    let message: string;
    if (clause >= 0 && read[clause]) {
      message = `duplicate '${CLAUSE_ORDER[clause]}' clause`;
    } else if (clause >= 0 && lastRead >= 0) {
      message = `'${CLAUSE_ORDER[clause]}' must come before '${CLAUSE_ORDER[lastRead]}'`;
    } else {
      message = `unexpected '${this.text(token)}' after the schedule`;
    }
    return this.error(message, token.start, token.end);
  }

  checkNamedUntil(schedule: ScheduleData): void {
    const until = schedule.until;
    if (
      until?.type !== "named" ||
      schedule.anchor !== null ||
      this.untilRange === null
    ) {
      return;
    }
    const [start, end] = this.untilRange;
    throw HronError.parse(
      `until ${until.month} ${until.day} has no year: add a starting date, or use an ISO date`,
      codePointSpan(this.input, start, end),
      this.input,
      `until ${until.month} ${until.day} starting YYYY-MM-DD`,
    );
  }

  private parseDateList(): DateSpec[] {
    const dates = [this.parseDate()];
    while (this.eat("comma")) {
      dates.push(this.parseDate());
    }
    return dates;
  }

  private parseDate(): DateSpec {
    if (this.peekIs("isoDate")) {
      return { type: "iso", date: this.isoDate(this.advance()) };
    }
    const month = this.peekIs("monthName");
    if (month) {
      this.advance();
      return {
        type: "named",
        month: month.name,
        day: this.parseDayOf(month.name),
      };
    }
    throw this.expected(EXPECTED.date);
  }

  private isoDate(token: Token): string {
    const date = this.text(token);
    if (!isCalendarDate(date)) {
      throw this.error(
        `date must be a calendar date from 0001-01-01 to 9999-12-31, got ${date}`,
        token.start,
        token.end,
      );
    }
    return date;
  }

  private timezone(token: Token): string {
    const name = this.text(token);
    const canonical = canonicalTimezone(name);
    if (canonical === null) {
      throw this.error(
        `timezone must be UTC or an Area/Location name such as America/New_York, got ${name}`,
        token.start,
        token.end,
      );
    }
    return canonical;
  }

  private parseEvery(): ScheduleExpr {
    const kind = this.peekKind();
    switch (kind?.type) {
      case "day":
        this.advance();
        return this.parseDayRepeat(1, { type: "every" });
      case "weekday":
        this.advance();
        return this.parseDayRepeat(1, { type: "weekday" });
      case "weekend":
        this.advance();
        return this.parseDayRepeat(1, { type: "weekend" });
      case "dayName":
        return this.parseDayRepeat(1, {
          type: "days",
          days: this.parseDayList(),
        });
      case "weeks":
        this.advance();
        return this.parseWeekRepeat(1);
      case "month":
        this.advance();
        return this.parseMonthRepeat(1);
      case "year":
        this.advance();
        return this.parseYearRepeat(1);
      case "number":
        return this.parseNumberRepeat(kind.value);
    }
    throw this.expected(EXPECTED.repeater);
  }

  private parseDayRepeat(interval: number, days: DayFilter): ScheduleExpr {
    this.expect("at", EXPECTED.at);
    const times = this.parseTimeList();
    return { type: "dayRepeat", interval, days, times };
  }

  private parseNumberRepeat(interval: number): ScheduleExpr {
    const number = this.advance();
    if (interval === 0) {
      throw this.error(
        `interval must be 1-2147483647, got ${this.text(number)}`,
        number.start,
        number.end,
      );
    }

    const kind = this.peekKind();
    switch (kind?.type) {
      case "weeks":
        this.advance();
        return this.parseWeekRepeat(interval);
      case "intervalUnit":
        this.advance();
        return this.parseIntervalRepeat(interval, kind.unit);
      case "day":
        this.advance();
        return this.parseDayRepeat(interval, { type: "every" });
      case "month":
        this.advance();
        return this.parseMonthRepeat(interval);
      case "year":
        this.advance();
        return this.parseYearRepeat(interval);
    }
    throw this.expected(EXPECTED.unit);
  }

  private parseIntervalRepeat(
    interval: number,
    unit: IntervalUnit,
  ): ScheduleExpr {
    this.expect("from", EXPECTED.from);
    const from = this.parseTime();
    const fromToken = this.previous();
    this.expect("to", EXPECTED.to);
    const to = this.parseTime();
    const toToken = this.previous();
    if (from.hour * 60 + from.minute > to.hour * 60 + to.minute) {
      throw this.error(
        `time window must not run backwards: ${this.text(fromToken)} to ${this.text(toToken)} (a window cannot cross midnight)`,
        fromToken.start,
        toToken.end,
      );
    }

    const dayFilter = this.eat("on") ? this.parseDayTarget() : null;
    return { type: "intervalRepeat", interval, unit, from, to, dayFilter };
  }

  private parseWeekRepeat(interval: number): ScheduleExpr {
    this.expect("on", EXPECTED.on);
    const days = this.parseDayList();
    this.expect("at", EXPECTED.at);
    const times = this.parseTimeList();
    return { type: "weekRepeat", interval, days, times };
  }

  private parseMonthRepeat(interval: number): ScheduleExpr {
    this.expect("on", EXPECTED.on);
    this.expect("the", EXPECTED.the);

    let target: MonthTarget;
    const kind = this.peekKind();
    switch (kind?.type) {
      case "last":
        this.advance();
        target = this.parseMonthLast();
        break;
      case "ordinal":
        this.advance();
        target = {
          type: "ordinalWeekday",
          ordinal: kind.name,
          weekday: this.parseDayName(),
        };
        break;
      case "ordinalNumber":
        target = { type: "days", specs: this.parseOrdinalDayList() };
        break;
      case "next":
      case "previous":
      case "nearest":
        target = this.parseNearestWeekdayTarget();
        break;
      default:
        throw this.expected(EXPECTED.monthTarget);
    }

    this.expect("at", EXPECTED.at);
    const times = this.parseTimeList();
    return { type: "monthRepeat", interval, target, times };
  }

  private parseMonthLast(): MonthTarget {
    const kind = this.peekKind();
    let target: MonthTarget;
    switch (kind?.type) {
      case "day":
        target = { type: "lastDay" };
        break;
      case "weekday":
        target = { type: "lastWeekday" };
        break;
      case "dayName":
        target = {
          type: "ordinalWeekday",
          ordinal: "last",
          weekday: kind.name,
        };
        break;
      default:
        throw this.expected(EXPECTED.monthLast);
    }
    this.advance();
    return target;
  }

  private parseNearestWeekdayTarget(): MonthTarget {
    let direction: NearestDirection | null = null;
    if (this.eat("next")) {
      direction = "next";
    } else if (this.eat("previous")) {
      direction = "previous";
    }
    this.expect("nearest", EXPECTED.nearest);
    this.expect("weekday", EXPECTED.weekday);
    this.expect("to", EXPECTED.to);
    const day = this.parseOrdinalDay();
    return { type: "nearestWeekday", day, direction };
  }

  private parseOrdinalDayList(): DayOfMonthSpec[] {
    const specs = [this.parseOrdinalDaySpec()];
    while (this.eat("comma")) {
      specs.push(this.parseOrdinalDaySpec());
    }
    return specs;
  }

  private parseOrdinalDaySpec(): DayOfMonthSpec {
    const start = this.parseOrdinalDay();
    const startToken = this.previous();
    if (!this.eat("to")) {
      return { type: "single", day: start };
    }
    const end = this.parseOrdinalDay();
    const endToken = this.previous();
    if (start > end) {
      throw this.error(
        `day range must not run backwards: ${this.text(startToken)} to ${this.text(endToken)}`,
        startToken.start,
        endToken.end,
      );
    }
    return { type: "range", start, end };
  }

  private parseOrdinalDay(): number {
    const kind = this.peekIs("ordinalNumber");
    if (!kind) throw this.expected(EXPECTED.dayOfMonth);
    return this.dayOfMonth(kind.value, this.advance());
  }

  private parseDayOf(month: MonthName): number {
    const kind = this.peekKind();
    if (kind?.type !== "number" && kind?.type !== "ordinalNumber") {
      throw this.expected(EXPECTED.dayNumber);
    }
    const token = this.advance();
    const day = this.dayOfMonth(kind.value, token);
    this.checkDayInMonth(day, token, month);
    return day;
  }

  private dayOfMonth(n: number, token: Token): number {
    if (n < 1 || n > 31) {
      throw this.error(
        `day must be 1-31, got ${this.text(token)}`,
        token.start,
        token.end,
      );
    }
    return n;
  }

  private checkDayInMonth(day: number, token: Token, month: MonthName): void {
    const max = MONTH_LENGTHS[month];
    if (day > max) {
      throw this.error(
        `day must be 1-${max} for ${month}, got ${this.text(token)}`,
        token.start,
        token.end,
      );
    }
  }

  private parseYearRepeat(interval: number): ScheduleExpr {
    this.expect("on", EXPECTED.on);

    let target: YearTarget;
    const kind = this.peekKind();
    if (kind?.type === "the") {
      this.advance();
      target = this.parseYearTargetAfterThe();
    } else if (kind?.type === "monthName") {
      this.advance();
      target = {
        type: "date",
        month: kind.name,
        day: this.parseDayOf(kind.name),
      };
    } else {
      throw this.expected(EXPECTED.yearTarget);
    }

    this.expect("at", EXPECTED.at);
    const times = this.parseTimeList();
    return { type: "yearRepeat", interval, target, times };
  }

  private parseYearTargetAfterThe(): YearTarget {
    const kind = this.peekKind();
    switch (kind?.type) {
      case "last": {
        this.advance();
        const next = this.peekKind();
        if (next?.type === "weekday") {
          this.advance();
          this.expect("of", EXPECTED.of);
          return { type: "lastWeekday", month: this.parseMonthName() };
        }
        if (next?.type === "dayName") {
          this.advance();
          this.expect("of", EXPECTED.of);
          const month = this.parseMonthName();
          return {
            type: "ordinalWeekday",
            ordinal: "last",
            weekday: next.name,
            month,
          };
        }
        throw this.expected(EXPECTED.yearLast);
      }
      case "ordinal": {
        this.advance();
        const weekday = this.parseDayName();
        this.expect("of", EXPECTED.of);
        const month = this.parseMonthName();
        return { type: "ordinalWeekday", ordinal: kind.name, weekday, month };
      }
      case "ordinalNumber": {
        const day = this.parseOrdinalDay();
        const dayToken = this.previous();
        this.expect("of", EXPECTED.of);
        const month = this.parseMonthName();
        this.checkDayInMonth(day, dayToken, month);
        return { type: "dayOfMonth", day, month };
      }
    }
    throw this.expected(EXPECTED.yearThe);
  }

  private parseMonthName(): MonthName {
    const kind = this.peekIs("monthName");
    if (!kind) throw this.expected(EXPECTED.monthName);
    this.advance();
    return kind.name;
  }

  private parseMonthList(): MonthName[] {
    const months = [this.parseMonthName()];
    while (this.eat("comma")) {
      months.push(this.parseMonthName());
    }
    return months;
  }

  private parseOn(): ScheduleExpr {
    const date = this.parseDate();
    this.expect("at", EXPECTED.at);
    const times = this.parseTimeList();
    return { type: "singleDate", date, times };
  }

  private parseDayTarget(): DayFilter {
    const kind = this.peekKind();
    switch (kind?.type) {
      case "day":
        this.advance();
        return { type: "every" };
      case "weekday":
        this.advance();
        return { type: "weekday" };
      case "weekend":
        this.advance();
        return { type: "weekend" };
      case "dayName":
        return { type: "days", days: this.parseDayList() };
    }
    throw this.expected(EXPECTED.dayTarget);
  }

  private parseDayName(): Weekday {
    const kind = this.peekIs("dayName");
    if (!kind) throw this.expected(EXPECTED.dayName);
    this.advance();
    return kind.name;
  }

  private parseDayList(): Weekday[] {
    const days = [this.parseDayName()];
    while (this.eat("comma")) {
      days.push(this.parseDayName());
    }
    return days;
  }

  private parseTimeList(): TimeOfDay[] {
    const times = [this.parseTime()];
    while (this.eat("comma")) {
      times.push(this.parseTime());
    }
    return times;
  }

  private parseTime(): TimeOfDay {
    const kind = this.peekIs("time");
    if (!kind) throw this.expected(EXPECTED.time);
    this.advance();
    return { hour: kind.hour, minute: kind.minute };
  }
}

function isCalendarDate(date: string): boolean {
  const [year, month, day] = date.split("-").map(Number);
  if (year < 1 || month < 1 || month > 12 || day < 1) return false;
  const leap = (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
  const lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return day <= lengths[month - 1];
}

/**
 * Null unless `name` is `UTC` or a known Area/Location zone or link
 * (spec/README.md, "Parse-time validation").
 */
function canonicalTimezone(name: string): string | null {
  const lower = asciiLowercase(name);
  if (lower === "utc") return "UTC";
  // Temporal also accepts offsets and bracketed date-time strings as zones,
  // and Intl knows legacy trees that are not IANA names.
  if (!/^[A-Za-z0-9_+-]+(\/[A-Za-z0-9_+-]+)+$/.test(name)) return null;
  if (["systemv/", "posix/", "right/"].some((tree) => lower.startsWith(tree))) {
    return null;
  }
  try {
    // For an IANA name Temporal returns the IANA capitalization, and a link
    // keeps its own name.
    return new Temporal.ZonedDateTime(0n, name).timeZoneId;
  } catch {
    return null;
  }
}

export function parse(input: string): ScheduleData {
  const tokens = tokenize(input);
  if (tokens.length === 0) {
    throw HronError.parse("empty expression", { start: 0, end: 0 }, input);
  }

  const parser = new Parser(tokens, input);
  const expr = parser.parseExpression();
  const schedule = parser.parseClauses(expr);
  if (parser.peek() !== undefined) {
    throw parser.leftover(schedule);
  }
  // spec/README.md, "Parse errors": every other error wins over a named until without starting.
  parser.checkNamedUntil(schedule);
  return schedule;
}
