/**
 * The part of the input an error points at: `[start, end)` counted in code
 * points, not UTF-16 units. A lone surrogate counts as one code point.
 */
export interface Span {
  start: number;
  end: number;
}

/**
 * `eval` is for schedules built in code from their parts. This package builds
 * them only by `Schedule.parse` and `Schedule.fromCron`, so it never throws one;
 * the kind exists because spec/api.json lists it.
 */
export type HronErrorKind = "lex" | "parse" | "eval" | "cron";

/** All errors produced by hron. */
export class HronError extends Error {
  readonly kind: HronErrorKind;
  readonly span?: Span;
  readonly input?: string;
  readonly suggestion?: string;

  constructor(
    kind: HronErrorKind,
    message: string,
    span?: Span,
    input?: string,
    suggestion?: string,
  ) {
    super(message);
    this.name = "HronError";
    this.kind = kind;
    this.span = span;
    this.input = input;
    this.suggestion = suggestion;
  }

  /**
   * Throws a `TypeError` if `message` or `input` is not a string, or `span` is
   * not an object whose `start` and `end` are numbers.
   */
  static lex(message: string, span: Span, input: string): HronError {
    return new HronError(
      "lex",
      text(message, "message"),
      checkedSpan(span),
      text(input, "input"),
    );
  }

  /**
   * Throws a `TypeError` if `message` or `input` is not a string, `span` is not
   * an object whose `start` and `end` are numbers, or `suggestion` is neither a
   * string nor `undefined`.
   */
  static parse(
    message: string,
    span: Span,
    input: string,
    suggestion?: string,
  ): HronError {
    return new HronError(
      "parse",
      text(message, "message"),
      checkedSpan(span),
      text(input, "input"),
      suggestion === undefined ? undefined : text(suggestion, "suggestion"),
    );
  }

  /**
   * Never thrown by this package; spec/api.json lists it with the other kinds.
   * Throws a `TypeError` if `message` is not a string.
   */
  static eval(message: string): HronError {
    return new HronError("eval", text(message, "message"));
  }

  /** Throws a `TypeError` if `message` is not a string. */
  static cron(message: string): HronError {
    return new HronError("cron", text(message, "message"));
  }

  /**
   * The message, then for `lex` and `parse` errors the input and a line of
   * carets under the span, and any suggestion as ` try: "..."`. No trailing newline.
   */
  displayRich(): string {
    if (
      (this.kind !== "lex" && this.kind !== "parse") ||
      this.span === undefined ||
      this.input === undefined
    ) {
      return `error: ${this.message}`;
    }
    // A tab, CR or LF would move the input off the line the carets are aligned to.
    const shown = this.input.replace(/[\t\r\n]/g, " ");
    const spaces = " ".repeat(this.span.start);
    const carets = "^".repeat(Math.max(this.span.end - this.span.start, 1));
    let out = `error: ${this.message}\n  ${shown}\n  ${spaces}${carets}`;
    if (this.suggestion !== undefined) {
      out += ` try: "${this.suggestion}"`;
    }
    return out;
  }
}

export function text(value: unknown, name: string): string {
  if (typeof value !== "string")
    throw new TypeError(`${name} must be a string`);
  return value;
}

function checkedSpan(value: unknown): Span {
  const span = value as Partial<Span> | null | undefined;
  if (typeof span?.start !== "number" || typeof span.end !== "number")
    throw new TypeError(
      "span must be an object whose start and end are numbers",
    );
  return value as Span;
}

// Token offsets are UTF-16 units; spans count code points (spec/README.md, "Error Structure").
export function codePointSpan(input: string, start: number, end: number): Span {
  const before = codePointCount(input.slice(0, start));
  return {
    start: before,
    end: before + codePointCount(input.slice(start, end)),
  };
}

function codePointCount(text: string): number {
  let count = 0;
  for (const _ of text) count++;
  return count;
}
