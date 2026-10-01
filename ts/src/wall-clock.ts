// A wall time a fall-back repeats takes its first pass (spec/README.md, "DST
// fall-back (ambiguous times)").

import { Temporal } from "@js-temporal/polyfill";
import type { TimeOfDay } from "./ast.js";

export const MINUTES_PER_HOUR = 60;
const MINUTE_MS = 60_000;
export const DAY_MS = 86_400_000;

/**
 * Entries each Zone cache holds before it starts over. Every time on a date
 * reads the same offsets, and a search revisits only the dates near its last
 * occurrence, so a few dozen keep the hits while bounding memory over a long
 * walk.
 */
const ZONE_CACHE_LIMIT = 64;

/**
 * Days from UTC midnight of the date before a date that hold every wall time
 * on it, and a time shifted from it onto the next date. Resolution assumes at
 * most one offset change in them.
 */
const TRANSITION_WINDOW_DAYS = 3;

export function minuteOfDay(time: TimeOfDay): number {
  return time.hour * MINUTES_PER_HOUR + time.minute;
}

/**
 * The Temporal polyfill costs microseconds per call, so offsets are looked up
 * once per date and wall times are resolved with plain arithmetic.
 */
export class Zone {
  private readonly midnightOffsets = new Map<number, number>();
  private readonly transitions = new Map<number, number>();

  constructor(readonly id: string) {}

  zoned(ms: number): Temporal.ZonedDateTime {
    return Temporal.Instant.fromEpochMilliseconds(ms).toZonedDateTimeISO(
      this.id,
    );
  }

  localDate(ms: number): number {
    return Math.floor((ms + this.offsetAt(ms)) / DAY_MS);
  }

  minuteStart(ms: number): number {
    const offset = this.offsetAt(ms);
    return Math.floor((ms + offset) / MINUTE_MS) * MINUTE_MS - offset;
  }

  /**
   * A time in a spring-forward gap shifts forward by the gap's length
   * (spec/README.md, "DST spring-forward (gaps)").
   */
  fixedTimeOn(date: number, minute: number): number {
    // Read at the offset before the gap, a wall time in it lands that much later.
    return (
      this.slotOn(date, minute) ??
      date * DAY_MS + minute * MINUTE_MS - this.offsetAtMidnight(date - 1)
    );
  }

  /**
   * Null when the slot falls in a spring-forward gap (spec/README.md,
   * "Interval slots in a spring-forward gap").
   */
  slotOn(date: number, minute: number): number | null {
    const local = date * DAY_MS + minute * MINUTE_MS;
    // Equal offsets at both ends of the window mean no change in it.
    const before = this.offsetAtMidnight(date - 1);
    const after = this.offsetAtMidnight(date - 1 + TRANSITION_WINDOW_DAYS);
    if (before === after) return local - before;
    const transition = this.transitionAfter(date - 1, before);
    if (local - before < transition) return local - before;
    if (local - after >= transition) return local - after;
    return null;
  }

  landingDate(date: number, instant: number): number {
    const before = this.offsetAtMidnight(date - 1);
    const after = this.offsetAtMidnight(date - 1 + TRANSITION_WINDOW_DAYS);
    const offset =
      before === after || instant < this.transitionAfter(date - 1, before)
        ? before
        : after;
    return Math.floor((instant + offset) / DAY_MS);
  }

  private offsetAt(ms: number): number {
    return this.zoned(ms).offsetNanoseconds / 1e6;
  }

  private offsetAtMidnight(date: number): number {
    let offset = this.midnightOffsets.get(date);
    if (offset === undefined) {
      if (this.midnightOffsets.size >= ZONE_CACHE_LIMIT) {
        this.midnightOffsets.clear();
      }
      offset = this.offsetAt(date * DAY_MS);
      this.midnightOffsets.set(date, offset);
    }
    return offset;
  }

  private transitionAfter(date: number, before: number): number {
    let at = this.transitions.get(date);
    if (at === undefined) {
      if (this.transitions.size >= ZONE_CACHE_LIMIT) this.transitions.clear();
      // Bisect rather than use getTimeZoneTransition, which in the polyfill
      // never returns when three offsets fall inside one of its search steps.
      let lo = date * DAY_MS;
      let hi = lo + TRANSITION_WINDOW_DAYS * DAY_MS;
      while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if (this.offsetAt(mid) === before) lo = mid;
        else hi = mid;
      }
      at = hi;
      this.transitions.set(date, at);
    }
    return at;
  }
}
