import { describe, expect, it } from "vitest";
import { HronError, Schedule, Temporal } from "../src/index.js";

const DAY_MS = 86_400_000;
const FULL_COMPARE_LIMIT = 20_000;

const BOTH_DAYS =
  "not expressible in hron: cron fires on either the day of month or the day of week";
const INTERVAL_DAYS =
  "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";

interface NaiveDate {
  key: string;
  ms: number;
  year: number;
  month: number;
  day: number;
  sundayZeroWeekday: number;
  daysInMonth: number;
  mondayToFridayDays: number[];
}

function naiveDate(year: number, month: number, day: number): NaiveDate {
  const weekdayOf = (d: number) =>
    new Date(Date.UTC(year, month - 1, d)).getUTCDay();
  const daysInMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const mondayToFridayDays: number[] = [];
  for (let d = 1; d <= daysInMonth; d++) {
    if (weekdayOf(d) !== 0 && weekdayOf(d) !== 6) mondayToFridayDays.push(d);
  }
  const pad = (n: number) => String(n).padStart(2, "0");
  return {
    key: `${year}-${pad(month)}-${pad(day)}`,
    ms: Date.UTC(year, month - 1, day),
    year,
    month,
    day,
    sundayZeroWeekday: weekdayOf(day),
    daysInMonth,
    mondayToFridayDays,
  };
}

function nextDay(d: NaiveDate): NaiveDate {
  const next = new Date(d.ms + DAY_MS);
  return naiveDate(
    next.getUTCFullYear(),
    next.getUTCMonth() + 1,
    next.getUTCDate(),
  );
}

// Two years around 2044-02-29, a leap day in a February with five Mondays.
const WINDOW_START = naiveDate(2043, 6, 1);
const WINDOW_END = naiveDate(2045, 6, 1);
const WINDOW_DAYS: NaiveDate[] = [];
for (let d = WINDOW_START; d.ms < WINDOW_END.ms; d = nextDay(d)) {
  WINDOW_DAYS.push(d);
}

type Time = [number, number];

type NaiveDom =
  | { type: "any" }
  | { type: "days"; set: boolean[] }
  | { type: "last" }
  | { type: "lastWeekday" }
  | { type: "nearest"; n: number };

type NaiveDow =
  | { type: "any" }
  | { type: "days"; set: boolean[] }
  | { type: "nth"; weekday: number; n: number }
  | { type: "last"; weekday: number };

const MONTH_NAMES = [
  "",
  "jan",
  "feb",
  "mar",
  "apr",
  "may",
  "jun",
  "jul",
  "aug",
  "sep",
  "oct",
  "nov",
  "dec",
];
const DAY_NAMES = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const SHORTCUTS: Record<string, string> = {
  "@yearly": "0 0 1 1 *",
  "@annually": "0 0 1 1 *",
  "@monthly": "0 0 1 * *",
  "@weekly": "0 0 * * 0",
  "@daily": "0 0 * * *",
  "@midnight": "0 0 * * *",
  "@hourly": "0 * * * *",
};

/**
 * A cron matcher written from the cron rules alone, sharing no code with the
 * package. It expects valid syntax.
 */
class NaiveCron {
  private readonly minutes: boolean[];
  private readonly hours: boolean[];
  private readonly months: boolean[];
  private readonly dom: NaiveDom;
  private readonly dow: NaiveDow;

  constructor(cron: string) {
    const lower = cron.trim().toLowerCase();
    const f = (SHORTCUTS[lower] ?? lower).split(/\s+/);
    expect(f.length, `naive matcher given ${cron}`).toBe(5);
    this.minutes = naiveSet(f[0], 0, 59, 59, []);
    this.hours = naiveSet(f[1], 0, 23, 23, []);
    this.months = naiveSet(f[3], 1, 12, 12, MONTH_NAMES);
    const dom = f[2];
    if (dom === "*" || dom === "?") {
      this.dom = { type: "any" };
    } else if (dom === "l") {
      this.dom = { type: "last" };
    } else if (dom === "lw") {
      this.dom = { type: "lastWeekday" };
    } else if (dom.endsWith("w")) {
      this.dom = { type: "nearest", n: naiveNumber(dom.slice(0, -1), []) };
    } else {
      this.dom = { type: "days", set: naiveSet(dom, 1, 31, 31, []) };
    }
    const dow = f[4];
    if (dow === "*" || dow === "?") {
      this.dow = { type: "any" };
    } else if (dow.includes("#")) {
      const [day, nth] = dow.split("#");
      this.dow = {
        type: "nth",
        weekday: naiveNumber(day, DAY_NAMES) % 7,
        n: naiveNumber(nth, []),
      };
    } else if (dow.endsWith("l")) {
      this.dow = {
        type: "last",
        weekday: naiveNumber(dow.slice(0, -1), DAY_NAMES) % 7,
      };
    } else {
      const set = naiveSet(dow, 0, 7, 6, DAY_NAMES);
      set[0] ||= set[7];
      this.dow = { type: "days", set: set.slice(0, 7) };
    }
  }

  times(): Time[] {
    const times: Time[] = [];
    for (let hour = 0; hour < 24; hour++) {
      for (let minute = 0; minute < 60; minute++) {
        if (this.hours[hour] && this.minutes[minute])
          times.push([hour, minute]);
      }
    }
    return times;
  }

  firesOn(d: NaiveDate): boolean {
    const {
      day,
      daysInMonth: last,
      sundayZeroWeekday: weekday,
      mondayToFridayDays,
    } = d;
    let dom: boolean | null = null;
    switch (this.dom.type) {
      case "days":
        dom = this.dom.set[day];
        break;
      case "last":
        dom = day === last;
        break;
      case "lastWeekday":
        dom = day === mondayToFridayDays[mondayToFridayDays.length - 1];
        break;
      case "nearest": {
        const { n } = this.dom;
        let nearest = mondayToFridayDays[0];
        for (const w of mondayToFridayDays) {
          if (Math.abs(w - n) < Math.abs(nearest - n)) nearest = w;
        }
        dom = n <= last && day === nearest;
        break;
      }
    }
    let dow: boolean | null = null;
    switch (this.dow.type) {
      case "days":
        dow = this.dow.set[weekday];
        break;
      case "nth":
        dow =
          weekday === this.dow.weekday &&
          Math.floor((day - 1) / 7) + 1 === this.dow.n;
        break;
      case "last":
        dow = weekday === this.dow.weekday && day + 7 > last;
        break;
    }
    const dayMatches =
      dom === null && dow === null ? true : (dom ?? false) || (dow ?? false);
    return this.months[d.month] && dayMatches;
  }

  bothDaysRestricted(): boolean {
    return this.dom.type !== "any" && this.dow.type !== "any";
  }

  daysCarryAnInterval(): boolean {
    if (this.dom.type === "any") {
      return this.dow.type === "any" || this.dow.type === "days";
    }
    return (
      this.dom.type === "days" &&
      this.dow.type === "any" &&
      this.dom.set.slice(1).every((d) => d)
    );
  }
}

function naiveNumber(text: string, names: string[]): number {
  const index = names.indexOf(text);
  return index >= 0 ? index : Number(text);
}

function naiveSet(
  field: string,
  min: number,
  max: number,
  starMax: number,
  names: string[],
): boolean[] {
  const set: boolean[] = new Array(max + 1).fill(false);
  for (const item of field.split(",")) {
    const [range, stepText] = item.split("/");
    const step = stepText === undefined ? null : naiveNumber(stepText, []);
    let low: number;
    let high: number;
    if (range === "*") {
      [low, high] = [min, starMax];
    } else if (range.includes("-")) {
      const [a, b] = range.split("-");
      [low, high] = [naiveNumber(a, names), naiveNumber(b, names)];
    } else {
      low = naiveNumber(range, names);
      high = step === null ? low : Math.max(low, starMax);
    }
    for (let value = low; value <= high; value += step ?? 1) {
      set[value] = true;
    }
  }
  return set;
}

function utc(
  d: NaiveDate,
  hour: number,
  minute: number,
): Temporal.ZonedDateTime {
  return Temporal.Instant.fromEpochMilliseconds(
    d.ms + (hour * 60 + minute) * 60_000,
  ).toZonedDateTimeISO("UTC");
}

function wall(z: Temporal.ZonedDateTime | null): string | null {
  return z === null ? null : `${z.toPlainDate()} ${z.hour}:${z.minute}`;
}

function occurrence(d: NaiveDate, [hour, minute]: Time): string {
  return `${d.key} ${hour}:${minute}`;
}

function assertFiresAs(
  schedule: Schedule,
  cron: NaiveCron,
  label: string,
): void {
  const times = cron.times();
  const days = WINDOW_DAYS.filter((d) => cron.firesOn(d));
  if (days.length * times.length <= FULL_COMPARE_LIMIT) {
    assertEachOccurrence(schedule, days, times, WINDOW_END, label);
    return;
  }
  assertEachOccurrence(
    schedule,
    days.slice(0, 2),
    times,
    nextDay(days[1]),
    label,
  );
  // Too many to compare one by one. In UTC an hron schedule fires at the same
  // times on every day it fires, so the two days compared in full stand for the
  // times of the rest; on each day the first and the last time, searched from
  // the day before, show that it fires that day and on no day between.
  let cursor = utc(WINDOW_START, 0, 0).subtract({ seconds: 1 });
  for (const d of days) {
    expect(
      wall(schedule.nextFrom(cursor)),
      `${label}: first time on ${d.key}`,
    ).toBe(occurrence(d, times[0]));
    const endOfDay = utc(nextDay(d), 0, 0);
    expect(
      wall(schedule.previousFrom(endOfDay)),
      `${label}: last time on ${d.key}`,
    ).toBe(occurrence(d, times[times.length - 1]));
    cursor = endOfDay.subtract({ seconds: 1 });
  }
  const after = schedule.nextFrom(cursor);
  expect(
    after === null || after.toPlainDate().toString() >= WINDOW_END.key,
    `${label}: fires on ${after}, after the last day the cron fires`,
  ).toBe(true);
}

function assertEachOccurrence(
  schedule: Schedule,
  days: NaiveDate[],
  times: Time[],
  end: NaiveDate,
  label: string,
): void {
  const from = utc(WINDOW_START, 0, 0).subtract({ seconds: 1 });
  const to = utc(end, 0, 0).subtract({ seconds: 1 });
  const expected = days.flatMap((d) => times.map((t) => occurrence(d, t)));
  let i = 0;
  for (const z of schedule.between(from, to)) {
    const actual = wall(z);
    if (actual !== expected[i]) {
      expect(actual, `${label}: occurrence ${i}`).toBe(expected[i]);
    }
    i++;
  }
  expect(i, `${label}: occurrences`).toBe(expected.length);
}

function hasEqualGaps(times: Time[]): boolean {
  const minutes = times.map(([h, m]) => h * 60 + m);
  return (
    minutes.length >= 3 &&
    minutes.every(
      (minute, i) =>
        i === 0 || minute - minutes[i - 1] === minutes[1] - minutes[0],
    )
  );
}

function tooManyMessage(times: Time[]): string {
  return hasEqualGaps(times)
    ? INTERVAL_DAYS
    : `not expressible in hron: ${times.length} times a day are too many to list`;
}

function cronMessage(run: () => unknown): string {
  let error: unknown = null;
  try {
    run();
  } catch (e) {
    error = e;
  }
  expect(error, "a HronError").toBeInstanceOf(HronError);
  expect((error as HronError).kind).toBe("cron");
  return (error as HronError).message;
}

function attempt<T>(label: string, run: () => T): T {
  try {
    return run();
  } catch (e) {
    throw new Error(`${label}: ${e}`);
  }
}

const MASK = (1n << 64n) - 1n;

/** xorshift64*, so the generated cases are the same on every run. */
class Rng {
  constructor(private state: bigint) {}

  pick<T>(items: readonly T[]): T {
    return items[this.pickIndex(items.length)];
  }

  pickIndex(length: number): number {
    this.state ^= this.state >> 12n;
    this.state ^= (this.state << 25n) & MASK;
    this.state ^= this.state >> 27n;
    const n = ((this.state * 0x2545f4914f6cdd1dn) & MASK) >> 32n;
    return Number(n % BigInt(length));
  }
}

const MINUTE_FIELDS = [
  "0",
  "30",
  "*/15",
  "0-30/10",
  "5,35",
  "*",
  "59",
  "*/7",
  "00",
  "10-50/20",
  "45/5",
  "0/20",
  "1-3",
  "*/99999999999999999999",
  "0,15,30,45",
  "5-10/5",
  "0-59/30",
  "*/20",
];
const HOUR_FIELDS = [
  "9",
  "*",
  "*/2",
  "9-17",
  "9-17/2",
  "0,12",
  "23",
  "0-20/4",
  "*/5",
  "22,0,2",
  "1-23",
  "7/30",
  "009",
  "0-11",
  "*/1",
  "12-12/250",
  "0-16/4",
  "1-21/4",
];
const DOM_FIELDS = [
  "*",
  "1",
  "15",
  "31",
  "L",
  "LW",
  "15W",
  "1-5",
  "1-31/10",
  "?",
  "29",
  "30",
  "lw",
  "1W",
  "31W",
  "*/2",
  "1-31",
  "5-20/3",
  "15,1",
  "02",
  "l",
  "28-31",
  "30W",
  "29w",
  "1-30",
  "2-31",
];
const MONTH_FIELDS = [
  "*",
  "1",
  "JAN",
  "1-3",
  "*/3",
  "2",
  "dec",
  "4",
  "feb",
  "1,7",
  "jun-aug",
  "12,1",
  "*/12",
  "2/5",
  "12-12/250",
  "Sep",
  "2",
  "2",
];
const DOW_FIELDS = [
  "*",
  "1-5",
  "MON",
  "0",
  "7",
  "5L",
  "1#2",
  "SUN#1",
  "?",
  "1-5/2",
  "sat,sun",
  "0-7",
  "7/2",
  "5-7",
  "fri#5",
  "1#5",
  "0l",
  "mon-fri/2",
  "6,7",
  "7,1",
  "0-6",
  "5/1",
  "*/3",
  "tue-thu",
  "1,1,3",
  "1-4",
  "mon-thu",
  "1-6",
  "0-5",
  "0,6,1",
  "sun,sat",
];

// Two crons in three keep one day field `*`, so most convert; the third draws
// both, so some are rejected for restricting both.
function generatedCrons(shard: number): string[] {
  const rng = new Rng(0x9e3779b97f4a7c15n ^ BigInt(shard));
  return Array.from({ length: 150 }, (_, i) => {
    const dom = i % 3 === 1 ? ["*"] : DOM_FIELDS;
    const dow = i % 3 === 0 ? ["*"] : DOW_FIELDS;
    return [MINUTE_FIELDS, HOUR_FIELDS, dom, MONTH_FIELDS, dow]
      .map((field) => rng.pick(field))
      .join(" ");
  });
}

function checkFromCron(shard: number): void {
  let accepted = 0;
  for (const cron of generatedCrons(shard)) {
    const naive = new NaiveCron(cron);
    const times = naive.times();
    if (naive.bothDaysRestricted()) {
      expect(
        cronMessage(() => Schedule.fromCron(cron)),
        cron,
      ).toBe(BOTH_DAYS);
      continue;
    }
    const interval = naive.daysCarryAnInterval() && hasEqualGaps(times);
    if (times.length > 24 && !interval) {
      expect(
        cronMessage(() => Schedule.fromCron(cron)),
        cron,
      ).toBe(tooManyMessage(times));
      continue;
    }
    const schedule = attempt(`fromCron(${cron})`, () =>
      Schedule.fromCron(cron),
    );
    assertFiresAs(schedule, naive, cron);

    const back = attempt(`toCron of fromCron(${cron}) = ${schedule}`, () =>
      schedule.toCron(),
    );
    const again = attempt(`fromCron(${back}) from ${cron}`, () =>
      Schedule.fromCron(back),
    );
    const label = `${cron} -> ${schedule} -> ${back}`;
    if (again.toString() !== schedule.toString()) {
      assertFiresAs(again, naive, label);
    }
    const naiveBack = new NaiveCron(back);
    expect(naiveBack.times(), label).toEqual(times);
    for (const d of WINDOW_DAYS) {
      if (naiveBack.firesOn(d) !== naive.firesOn(d)) {
        expect(naiveBack.firesOn(d), `${label} on ${d.key}`).toBe(
          naive.firesOn(d),
        );
      }
    }
    accepted++;
  }
  expect(accepted, "generated crons accepted").toBeGreaterThanOrEqual(60);
}

const TIME_LISTS = [
  "09:00",
  "00:00",
  "23:59",
  "09:00, 17:00",
  "17:00, 09:00, 09:00",
  "00:00, 12:00",
  "09:00, 13:00, 17:00",
  "09:00, 17:30",
  "00:05, 00:35",
  "00:00, 00:01, 00:02, 00:30",
  "00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10",
  "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59",
  "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00",
  "09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00, 15:30",
  "09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12, 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24",
];
// Each with the month it names, which a `during` must include.
const DAY_EXPRESSIONS: [string, string | null][] = [
  ["every day", null],
  ["every weekday", null],
  ["every weekend", null],
  ["every monday", null],
  ["every sunday, saturday", null],
  ["every friday, saturday, sunday", null],
  ["every week on tuesday, friday", null],
  ["every 1 day", null],
  ["every month on the 1st", null],
  ["every month on the 1st to 5th, 20th", null],
  ["every month on the 31st", null],
  ["every month on the 15th, 1st", null],
  ["every month on the 1st to 31st", null],
  ["every month on the last day", null],
  ["every month on the last weekday", null],
  ["every month on the nearest weekday to 1st", null],
  ["every month on the nearest weekday to 31st", null],
  ["every month on the nearest weekday to 15th", null],
  ["every month on the first monday", null],
  ["every month on the fifth friday", null],
  ["every month on the last sunday", null],
  ["every year on feb 29", "feb"],
  ["every year on dec 25", "dec"],
  ["every year on the 15th of march", "mar"],
  ["every year on the first monday of mar", "mar"],
  ["every year on the fifth monday of feb", "feb"],
  ["every year on the last friday of feb", "feb"],
  ["every year on the last weekday of dec", "dec"],
  ["on feb 14", "feb"],
  ["on feb 29", "feb"],
];
const INTERVALS = [
  "every 30 min from 09:00 to 17:30",
  "every 15 min from 00:00 to 23:59",
  "every 2 hours from 00:00 to 23:59",
  "every 7 hours from 00:00 to 23:59",
  "every 45 min from 09:00 to 17:00",
  "every 20 min from 09:00 to 17:40",
  "every 1 minute from 00:00 to 23:59",
  "every 120 min from 01:00 to 23:00",
  "every 2147483647 hours from 00:00 to 23:59",
  "every 5 min from 10:00 to 10:30",
  "every 4 hours from 00:00 to 20:00",
  "every 1 hour from 09:05 to 17:05",
  "every 30 min from 09:00 to 17:00",
];
const INTERVAL_DAY_FILTERS = [
  "",
  " on weekday",
  " on weekend",
  " on monday, friday",
];
const DURING = [
  "",
  "",
  " during feb",
  " during dec",
  " during jan, jul",
  " during dec, jan, feb",
  " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
];

interface GeneratedSchedule {
  hron: string;
  times: number[];
  ownMonth: string | null;
  during: string;
}

function generatedSchedules(): GeneratedSchedule[] {
  const rng = new Rng(0x2545f4914f6cdd1dn);
  return Array.from({ length: 240 }, (_, i) => {
    const during = rng.pick(DURING);
    if (i % 3 === 0) {
      const filter = rng.pick(INTERVAL_DAY_FILTERS);
      const interval = rng.pick(INTERVALS);
      return {
        hron: `${interval}${filter}${during}`,
        times: naiveIntervalTimes(interval),
        ownMonth: null,
        during,
      };
    }
    const [days, ownMonth] =
      DAY_EXPRESSIONS[rng.pickIndex(DAY_EXPRESSIONS.length)];
    const times = rng.pick(TIME_LISTS);
    return {
      hron: `${days} at ${times}${during}`,
      times: times.split(", ").map(naiveMinuteOfDay),
      ownMonth,
      during,
    };
  });
}

function naiveMinuteOfDay(time: string): number {
  const [hour, minute] = time.split(":");
  return Number(hour) * 60 + Number(minute);
}

function naiveIntervalTimes(interval: string): number[] {
  const words = interval.split(" ");
  const every = Number(words[1]);
  const step = words[2].startsWith("hour") ? every * 60 : every;
  const from = naiveMinuteOfDay(words[4]);
  const to = naiveMinuteOfDay(words[6]);
  const times: number[] = [];
  for (let t = from; t <= to; t++) {
    if ((t - from) % step === 0) times.push(t);
  }
  return times;
}

/** The reason toCron must give, decided from the generated parts alone. */
function expectedToCronFailure(generated: GeneratedSchedule): string | null {
  const { ownMonth, during } = generated;
  if (ownMonth !== null && during !== "" && !during.includes(ownMonth)) {
    return "during excludes the schedule's month";
  }
  const count = (values: number[]) => new Set(values).size;
  const times = count(generated.times);
  const minutes = count(generated.times.map((t) => t % 60));
  const hours = count(generated.times.map((t) => Math.floor(t / 60)));
  return minutes * hours !== times
    ? "times are not every combination of their minutes and hours"
    : null;
}

describe("cron exactness", () => {
  for (const shard of [0, 1, 2, 3]) {
    it(`fromCron is exact, shard ${shard}`, () => {
      checkFromCron(shard);
    });
  }

  it("toCron is exact", () => {
    let accepted = 0;
    let rejected = 0;
    for (const generated of generatedSchedules()) {
      const { hron } = generated;
      const schedule = attempt(`parse(${hron})`, () => Schedule.parse(hron));
      const reason = expectedToCronFailure(generated);
      if (reason !== null) {
        expect(
          cronMessage(() => schedule.toCron()),
          hron,
        ).toBe(`not expressible as cron: ${reason}`);
        rejected++;
        continue;
      }
      const cron = attempt(`toCron(${hron})`, () => schedule.toCron());
      const naive = new NaiveCron(cron);
      assertFiresAs(schedule, naive, `${hron} -> ${cron}`);
      accepted++;

      const times = naive.times();
      const label = `${hron} -> ${cron} -> fromCron`;
      const interval = naive.daysCarryAnInterval() && hasEqualGaps(times);
      if (times.length > 24 && !interval) {
        expect(
          cronMessage(() => Schedule.fromCron(cron)),
          label,
        ).toBe(tooManyMessage(times));
        continue;
      }
      const back = attempt(label, () => Schedule.fromCron(cron));
      assertFiresAs(back, naive, label);
    }
    expect(accepted, "generated schedules converted").toBeGreaterThanOrEqual(
      60,
    );
    expect(rejected, "generated schedules rejected").toBeGreaterThanOrEqual(20);
  }, 30_000);

  it("the naive matcher agrees with known dates", () => {
    const fires = (cron: string, year: number, month: number, day: number) =>
      new NaiveCron(cron).firesOn(naiveDate(year, month, day));
    expect(fires("0 9 * 2 1#5", 2044, 2, 29)).toBe(true);
    expect(
      fires("0 9 1W * *", 2043, 8, 3),
      "Saturday the 1st moves to Monday",
    ).toBe(true);
    expect(fires("0 9 31W * *", 2043, 8, 31), "Monday the 31st").toBe(true);
    expect(
      fires("0 9 30W * *", 2044, 4, 29),
      "Saturday the 30th moves to Friday",
    ).toBe(true);
    expect(
      fires("0 9 31W * *", 2044, 7, 29),
      "Sunday the 31st moves to Friday",
    ).toBe(true);
    expect(fires("0 9 31W * *", 2044, 4, 30), "April has no 31st").toBe(false);
    expect(fires("0 9 LW * *", 2044, 4, 29)).toBe(true);
    expect(fires("0 9 * * 5L", 2044, 4, 29)).toBe(true);
    expect(fires("0 9 * * 5L", 2044, 4, 22)).toBe(false);
  });
});

describe("cron numbers and fields", () => {
  it("reads values of any length without losing precision", () => {
    const longZeros = "0".repeat(10_000);
    const huge = "9".repeat(10_000);
    expect(
      Schedule.fromCron(`${longZeros}9 ${longZeros}9 * * *`).toString(),
    ).toBe("every day at 09:09");
    expect(cronMessage(() => Schedule.fromCron(`0 9 * * 1#${huge}`))).toBe(
      `day of week ordinal must be 1-5, got ${huge}`,
    );
    expect(cronMessage(() => Schedule.fromCron(`0 9 ${huge}W * *`))).toBe(
      `day of month must be 1-31, got ${huge}`,
    );
    expect(cronMessage(() => Schedule.fromCron(`0 ${huge}-1 * * *`))).toBe(
      `hour must be 0-23, got ${huge}`,
    );
    expect(Schedule.fromCron(`0 9 * * 1-5/${huge}`).toString()).toBe(
      "every monday at 09:00",
    );
    expect(cronMessage(() => Schedule.fromCron(`0 9 * * */${longZeros}`))).toBe(
      "day of week step must be at least 1",
    );
    expect(Schedule.fromCron(`0 9 * * 0-7/${longZeros}7`).toString()).toBe(
      "every sunday at 09:00",
    );
  });

  it("parses a long field in linear time", () => {
    const items = new Array(200_000).fill("1").join(",");
    expect(Schedule.fromCron(`0 9 ${items} * *`).toString()).toBe(
      "every month on the 1st at 09:00",
    );
    const ranges = new Array(50_000).fill("0-59/1").join(",");
    expect(Schedule.fromCron(`${ranges} 9 * * *`).toString()).toBe(
      "every 1 minute from 09:00 to 09:59",
    );
  });

  it("converts a step that does not divide the hour only within one hour", () => {
    expect(Schedule.fromCron("*/7 9 * * *").toString()).toBe(
      "every 7 min from 09:00 to 09:56",
    );
    expect(cronMessage(() => Schedule.fromCron("*/7 * * * *"))).toBe(
      "not expressible in hron: 216 times a day are too many to list",
    );
  });
});
