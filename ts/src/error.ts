/** Byte range within the input string. */
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

  displayRich(): string {
    if (
      (this.kind === "lex" || this.kind === "parse") &&
      this.span &&
      this.input
    ) {
      let out = `error: ${this.message}\n`;
      out += `  ${this.input}\n`;
      const padding = " ".repeat(this.span.start + 2);
      const underline = "^".repeat(Math.max(this.span.end - this.span.start, 1));
      out += padding + underline;
      if (this.suggestion) {
        out += ` try: "${this.suggestion}"`;
      }
      return out;
    }
    return `error: ${this.message}`;
  }
}
