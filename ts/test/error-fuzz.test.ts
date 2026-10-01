import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { Temporal } from "@js-temporal/polyfill";
import { expect, it } from "vitest";
import { HronError, Schedule, type Span } from "../src/index.js";

const INPUTS = 6000;
const SEED = 0x5eed4a0en;

const WHAT = [
  "'every' or 'on'",
  "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
  "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')",
  "'at'",
  "a time (HH:MM)",
  "'from'",
  "'to'",
  "'day', 'weekday', 'weekend' or a day name",
  "'on'",
  "a day name",
  "'the'",
  "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
  "'day', 'weekday' or a day name",
  "'nearest'",
  "'weekday'",
  "a day such as 15th",
  "a month name or 'the'",
  "a day such as 15th, 'last' or an ordinal such as 'first'",
  "'weekday' or a day name",
  "'of'",
  "a month name",
  "a day number",
  "a date (YYYY-MM-DD, or a month and day)",
  "a date (YYYY-MM-DD)",
  "a timezone",
]
  .map((what) => what.replace(/[()]/g, "\\$&"))
  .join("|");
const MONTH = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec";
// No `i` flag: with `u` it folds the Kelvin sign and long s into ASCII letters.
const DAY = "[0-9]+(?:[sS][tT]|[nN][dD]|[rR][dD]|[tT][hH])?";
const TIME = "[0-9]{1,2}:[0-9]{2}";

const CLAUSE_ORDER = ["except", "until", "starting", "during", "in"];
const TOKEN_SEPARATORS = [" ", "\t", "\r", "\n"];

interface Failure {
  input: string;
  span: Span;
  spanned: string;
}

type Groups = Record<string, string | undefined>;
type Problem = string;
type Check = (groups: Groups, failure: Failure) => Problem | null;

interface Template {
  kind: "lex" | "parse";
  regex: RegExp;
  check: Check;
}

function ensure(holds: boolean, problem: () => Problem): Problem | null {
  return holds ? null : problem();
}

// Saturates, since a digit run can be thousands of digits long.
function value(text: string): number {
  let n = 0;
  for (const c of text) {
    if (c < "0" || c > "9") break;
    n = Math.min(n * 10 + Number(c), Number.MAX_SAFE_INTEGER);
  }
  return n;
}

function asciiLowercase(text: string): string {
  return text.replace(/[A-Z]/g, (c) => c.toLowerCase());
}

function asciiUppercase(text: string): string {
  return text.replace(/[a-z]/g, (c) => c.toUpperCase());
}

function trimEndSeparators(text: string): string {
  let end = text.length;
  while (end > 0 && TOKEN_SEPARATORS.includes(text[end - 1])) end--;
  return text.slice(0, end);
}

const noCheck: Check = () => null;

// From spec/README.md, "Lex errors" and "Parse errors". A `span` group must
// equal the spanned text; every other group is read by its template's check.
function templates(): Template[] {
  const template = (
    kind: "lex" | "parse",
    pattern: string,
    check: Check,
  ): Template => ({ kind, regex: new RegExp(pattern, "su"), check });
  return [
    template("lex", "^unexpected character '(?<span>[!-&(-~])'$", (_, f) => {
      const c = f.spanned[0] ?? " ";
      return ensure(!/[A-Za-z0-9,]/.test(c), () => `'${c}' starts a token`);
    }),
    template(
      "lex",
      "^unexpected character U\\+(?<code>[0-9A-F]{4,})$",
      (g, f) => {
        const shown = Number.parseInt(g.code ?? "", 16);
        const quotable = shown >= 0x21 && shown <= 0x7e && shown !== 0x27;
        const chars = Array.from(f.spanned);
        return ensure(
          chars.length === 1 && chars[0].codePointAt(0) === shown && !quotable,
          () => `U+${g.code} does not describe '${f.spanned}'`,
        );
      },
    ),
    template(
      "lex",
      "^unknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'$",
      noCheck,
    ),
    template(
      "lex",
      "^time must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))$",
      (g) => {
        const hour = g.hour ?? "";
        const minute = g.minute ?? "";
        return ensure(
          hour.length < 1 || hour.length > 2 || minute.length !== 2,
          () => `${hour}:${minute} is H:MM or HH:MM`,
        );
      },
    ),
    template(
      "lex",
      "^time must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))$",
      (g) => {
        const hour = value(g.hour ?? "");
        const minute = value(g.minute ?? "");
        return ensure(
          hour > 23 || minute > 59,
          () => `${hour}:${minute} is in range`,
        );
      },
    ),
    template("lex", "^number must be at most 2147483647$", (_, f) =>
      ensure(
        /^[0-9]+$/.test(f.spanned) && value(f.spanned) > 2147483647,
        () => `'${f.spanned}' is not digits above 2147483647`,
      ),
    ),
    template("parse", "^empty expression$", (_, f) => {
      const blank = trimEndSeparators(f.input) === "";
      return ensure(
        blank && f.span.start === 0 && f.span.end === 0,
        () => `empty expression with span ${JSON.stringify(f.span)}`,
      );
    }),
    template(
      "parse",
      `^expected (?:${WHAT}), got (?:'(?<span>.+)'|(?<end>end of input))$`,
      (g, f) => {
        if (g.end === undefined) return null;
        const end = Array.from(trimEndSeparators(f.input)).length;
        return ensure(
          f.span.start === end && f.span.end === end,
          () => `end of input at ${JSON.stringify(f.span)}, expected ${end}`,
        );
      },
    ),
    template(
      "parse",
      "^interval must be 1-2147483647, got (?<span>[0-9]+)$",
      (_, f) =>
        ensure(value(f.spanned) === 0, () => `interval ${f.spanned} is valid`),
    ),
    template("parse", `^day must be 1-31, got (?<span>${DAY})$`, (_, f) => {
      const day = value(f.spanned);
      return ensure(day === 0 || day > 31, () => `day ${day} is within 1-31`);
    }),
    template(
      "parse",
      `^day must be 1-(?<max>[0-9]+) for (?<month>${MONTH}), got (?<span>${DAY})$`,
      (g, f) => {
        const month = g.month ?? "";
        const length =
          month === "feb"
            ? 29
            : ["apr", "jun", "sep", "nov"].includes(month)
              ? 30
              : 31;
        const max = value(g.max ?? "");
        const day = value(f.spanned);
        return ensure(
          max === length && day > max && day <= 31,
          () => `day ${day} against 1-${max} for ${month}`,
        );
      },
    ),
    template(
      "parse",
      `^day range must not run backwards: (?<a>${DAY}) to (?<b>${DAY})$`,
      (g, f) => {
        const a = g.a ?? "";
        const b = g.b ?? "";
        const spansBoth = f.spanned.startsWith(a) && f.spanned.endsWith(b);
        return ensure(
          spansBoth && value(a) > value(b),
          () => `${a} to ${b} against the span '${f.spanned}'`,
        );
      },
    ),
    template(
      "parse",
      `^time window must not run backwards: (?<from>${TIME}) to (?<to>${TIME}) \\(a window cannot cross midnight\\)$`,
      (g, f) => {
        const from = g.from ?? "";
        const to = g.to ?? "";
        const minutes = (t: string) => {
          const [hour, minute] = t.split(":");
          return value(hour) * 60 + value(minute);
        };
        const spansBoth = f.spanned.startsWith(from) && f.spanned.endsWith(to);
        return ensure(
          spansBoth && minutes(from) > minutes(to),
          () => `${from} to ${to} against the span '${f.spanned}'`,
        );
      },
    ),
    template(
      "parse",
      "^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?<span>[0-9]{4}-[0-9]{2}-[0-9]{2})$",
      (_, f) => {
        let calendar: boolean;
        try {
          calendar = Temporal.PlainDate.from(f.spanned).year >= 1;
        } catch {
          calendar = false;
        }
        return ensure(!calendar, () => `${f.spanned} is a calendar date`);
      },
    ),
    template(
      "parse",
      "^timezone must be UTC or an Area/Location name such as America/New_York, got (?<span>.+)$",
      noCheck,
    ),
    template(
      "parse",
      "^duplicate '(?<keyword>except|until|starting|during|in)' clause$",
      (g, f) =>
        ensure(
          g.keyword === asciiLowercase(f.spanned),
          () => `duplicate '${g.keyword}' but the span holds '${f.spanned}'`,
        ),
    ),
    template(
      "parse",
      "^'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'$",
      (g, f) => {
        const keyword = g.keyword ?? "";
        const last = g.last ?? "";
        const k = CLAUSE_ORDER.indexOf(keyword);
        const l = CLAUSE_ORDER.indexOf(last);
        const earlier = k >= 0 && l >= 0 && k < l;
        return ensure(
          earlier && keyword === asciiLowercase(f.spanned),
          () => `'${keyword}' before '${last}' with the span '${f.spanned}'`,
        );
      },
    ),
    template("parse", "^unexpected '(?<span>.+)' after the schedule$", noCheck),
    template(
      "parse",
      `^until (?<month>${MONTH}) (?<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date$`,
      (g, f) => {
        const words = f.spanned.split(/[ \t\r\n]/).filter((w) => w !== "");
        const endsAtDay = !TOKEN_SEPARATORS.includes(f.spanned.at(-1) ?? " ");
        const [until, month, day] = words;
        const matchesMessage =
          endsAtDay &&
          words.length === 3 &&
          asciiLowercase(until) === "until" &&
          asciiLowercase(month).startsWith(g.month ?? "") &&
          /^[0-9]/.test(day) &&
          String(value(day)) === g.day;
        return ensure(
          matchesMessage,
          () => `the span '${f.spanned}' is not 'until ${g.month} ${g.day}'`,
        );
      },
    ),
  ];
}

const FRAGMENTS = [
  "every",
  "on",
  "at",
  "from",
  "to",
  "in",
  "IN",
  "of",
  "the",
  "last",
  "except",
  "until",
  "starting",
  "during",
  "nearest",
  "next",
  "previous",
  "day",
  "Days",
  "weekdays",
  "weekend",
  "week",
  "month",
  "years",
  "min",
  "hrs",
  "monday",
  "FRI",
  "jan",
  "february",
  "first",
  "fifth",
  "0",
  "1",
  "00",
  "15th",
  "31ST",
  "2nd",
  "2147483647",
  "2147483648",
  "99999999999999999999",
  "09:00",
  "9:5",
  "24:00",
  "9:",
  "17:30",
  "2026-02-28",
  "2026-02-30",
  "0000-01-01",
  "12026-03-15",
  ",",
  ":",
  "-",
  "/",
  "'",
  '"',
  "#",
  "~",
  "_",
  "UTC",
  "America/New_York",
  "Nope/Zone",
  "Europe/\u0130stanbul",
  "\u00e9",
  "e\u0301",
  "\u212a",
  "\u017f",
  "\u00a0",
  "\u2028",
  "\ufeff",
  "\uff10",
  "\u{1f600}",
  "\u{10ffff}",
  "\u{1d7d8}",
  "\ud800",
  "\udfff",
  "\0",
  "\u000b",
  "\u000c",
  "\u007f",
  "\u001b",
  "toString",
  "__proto__",
];
const SEPARATORS = ["", " ", " ", " ", "  ", "\t", "\r\n", "\n"];

// SplitMix64: a fixed seed gives the same inputs on every run.
class Rng {
  private state: bigint;

  constructor(seed: bigint) {
    this.state = seed;
  }

  next(): bigint {
    const mask = (1n << 64n) - 1n;
    this.state = (this.state + 0x9e3779b97f4a7c15n) & mask;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & mask;
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & mask;
    return z ^ (z >> 31n);
  }

  below(n: number): number {
    return Number(this.next() % BigInt(n));
  }

  pick(items: string[]): string {
    return items[this.below(items.length)];
  }
}

function corpus(): string[] {
  const spec = JSON.parse(
    readFileSync(resolve(__dirname, "../../spec/tests.json"), "utf-8"),
  );
  const inputs: string[] = [];
  for (const section of Object.values(spec.parse)) {
    const tests = (section as { tests?: { input: string }[] }).tests ?? [];
    inputs.push(...tests.map((tc) => tc.input));
  }
  for (const tc of spec.parse_errors.tests) inputs.push(tc.input);
  return inputs;
}

function randomText(rng: Rng): string {
  let out = "";
  const count = rng.below(12) + 1;
  for (let i = 0; i < count; i++) {
    out += rng.pick(SEPARATORS);
    out += rng.pick(FRAGMENTS);
  }
  return out;
}

function mutate(rng: Rng, input: string): string {
  const words = input.split(" ");
  const i = rng.below(words.length);
  switch (rng.below(7)) {
    case 0:
      words.splice(i, 1);
      break;
    case 1: {
      const j = rng.below(words.length);
      [words[i], words[j]] = [words[j], words[i]];
      break;
    }
    case 2:
      words.splice(rng.below(words.length + 1), 0, words[i]);
      break;
    case 3: {
      const chars = Array.from(input);
      return chars.slice(0, rng.below(chars.length + 1)).join("");
    }
    case 4:
      words[i] = asciiUppercase(words[i]);
      break;
    case 5:
      words[i] = rng.pick(FRAGMENTS);
      break;
    default: {
      const fragment = rng.pick(FRAGMENTS);
      const chars = Array.from(words[i]);
      const at = rng.below(chars.length + 1);
      chars.splice(at, 0, fragment);
      words[i] = chars.join("");
    }
  }
  return words.join(" ");
}

const CLAUSES = [
  "except dec 25",
  "except 2026-12-25, jan 1",
  "until 2027-12-31",
  "until dec 31",
  "starting 2026-01-01",
  "during jan, jul",
  "in UTC",
  "IN America/New_York",
];

function withClauses(rng: Rng, input: string): string {
  let out = input;
  const count = rng.below(4) + 1;
  for (let i = 0; i < count; i++) {
    out += ` ${rng.pick(CLAUSES)}`;
  }
  return out;
}

function generate(rng: Rng, inputs: string[]): string {
  switch (rng.below(4)) {
    case 0:
      return randomText(rng);
    case 1:
      return withClauses(rng, inputs[rng.below(inputs.length)]);
    default: {
      let input = inputs[rng.below(inputs.length)];
      const count = rng.below(4);
      for (let i = 0; i < count; i++) input = mutate(rng, input);
      return input;
    }
  }
}

function check(
  input: string,
  error: unknown,
  all: Template[],
): number | Problem {
  if (!(error instanceof HronError)) return `not a HronError: ${error}`;
  if (error.kind !== "lex" && error.kind !== "parse") {
    return `neither lex nor parse: ${error.kind}`;
  }
  if (Schedule.validate(input)) return "validate is true";
  if (error.input !== input) {
    return `error input is ${JSON.stringify(error.input)}`;
  }
  const span = error.span;
  const chars = Array.from(input);
  if (span === undefined || span.start > span.end || span.end > chars.length) {
    return `span ${JSON.stringify(span)} outside 0..=${chars.length}`;
  }
  const failure: Failure = {
    input,
    span,
    spanned: chars.slice(span.start, span.end).join(""),
  };

  const index = all.findIndex(
    (t) => t.kind === error.kind && t.regex.test(error.message),
  );
  if (index < 0) {
    return `${error.kind} message '${error.message}' matches no template`;
  }
  const groups = all[index].regex.exec(error.message)?.groups ?? {};
  if (groups.span !== undefined && groups.span !== failure.spanned) {
    return `message echoes '${groups.span}' but the span holds '${failure.spanned}'`;
  }
  const problem = all[index].check(groups, failure);
  if (problem !== null) return problem;

  const expectedSuggestion = error.message.startsWith("until ")
    ? `until ${groups.month} ${groups.day} starting YYYY-MM-DD`
    : undefined;
  if (error.suggestion !== expectedSuggestion) {
    return `suggestion ${error.suggestion}, expected ${expectedSuggestion}`;
  }

  const rich = error.displayRich();
  if (
    rich.split("\n").length !== 3 ||
    !rich.startsWith(`error: ${error.message}\n`)
  ) {
    return `displayRich is not three lines: ${JSON.stringify(rich)}`;
  }
  return index;
}

it("generated inputs fail only with spec errors", () => {
  const all = templates();
  const inputs = corpus();
  const rng = new Rng(SEED);
  const hits = all.map(() => 0);
  let parsed = 0;
  const failures: string[] = [];

  for (let n = 0; n < INPUTS; n++) {
    const input = generate(rng, inputs);
    let error: unknown = null;
    try {
      Schedule.parse(input);
      parsed++;
      continue;
    } catch (e) {
      error = e;
    }
    const result = check(input, error, all);
    if (typeof result === "number") {
      hits[result]++;
    } else {
      failures.push(`${JSON.stringify(input)}: ${result}`);
    }
  }

  expect(failures.slice(0, 20), `${failures.length} failures`).toEqual([]);
  expect(parsed, "inputs that parsed").toBeGreaterThan(INPUTS / 20);
  const unused = all.filter((_, i) => hits[i] === 0).map((t) => t.regex.source);
  expect(unused, "templates no input produced").toEqual([]);
});

it("a message echoing U+2028 still matches its template", () => {
  const input = "every day at 09:00 in UTC ";
  let error: unknown = null;
  try {
    Schedule.parse(input);
  } catch (e) {
    error = e;
  }
  expect(check(input, error, templates())).toBeTypeOf("number");
});
