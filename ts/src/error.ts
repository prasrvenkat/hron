/**
 * The part of the input an error points at: `[start, end)` counted in code
 * points, not UTF-16 units. A lone surrogate counts as one code point.
 */
export interface Span {
  start: number;
  end: number;
}

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

  static lex(message: string, span: Span, input: string): HronError {
    return new HronError("lex", message, span, input);
  }

  static parse(
    message: string,
    span: Span,
    input: string,
    suggestion?: string,
  ): HronError {
    return new HronError("parse", message, span, input, suggestion);
  }

  static eval(message: string): HronError {
    return new HronError("eval", message);
  }

  static cron(message: string): HronError {
    return new HronError("cron", message);
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
