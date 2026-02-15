/**
 * Iterator-specific tests for `occurrences()` and `between()` methods.
 *
 * These tests verify TypeScript-specific iterator behavior beyond conformance tests:
 * - Laziness (generators don't evaluate eagerly)
 * - Early termination
 * - Iterator protocol (Symbol.iterator)
 * - Integration with Array.from and spread operator
 */

import { Temporal } from "@js-temporal/polyfill";
import { describe, expect, it } from "vitest";
import { Schedule } from "../src/index.js";

function parseZoned(s: string): Temporal.ZonedDateTime {
  return Temporal.ZonedDateTime.from(s);
}

// =============================================================================
// Laziness Tests
// =============================================================================

describe("laziness", () => {
  it("occurrences is lazy - does not evaluate unbounded schedule", () => {
    // An unbounded schedule should not hang or OOM when creating the iterator
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    // Creating the iterator should be instant (lazy)
    const iter = schedule.occurrences(from);

    // Taking just 1 should work without evaluating the rest
    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of iter) {
      results.push(dt);
      if (results.length >= 1) break;
    }
    expect(results.length).toBe(1);
  });

  it("between is lazy - does not evaluate entire range at once", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
    const to = parseZoned("2026-12-31T23:59:00+00:00[UTC]");

    // Creating the iterator should be instant
    const iter = schedule.between(from, to);

    // Taking just 3 should not evaluate all ~330 days
    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of iter) {
      results.push(dt);
      if (results.length >= 3) break;
    }
    expect(results.length).toBe(3);
  });
});

// =============================================================================
// Early Termination Tests
// =============================================================================

describe("early termination", () => {
  it("occurrences terminates with break", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of schedule.occurrences(from)) {
      results.push(dt);
      if (results.length >= 5) break;
    }

    expect(results.length).toBe(5);
  });

  it("occurrences terminates with conditional break", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
    const cutoff = parseZoned("2026-02-05T00:00:00+00:00[UTC]");

    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of schedule.occurrences(from)) {
      if (Temporal.ZonedDateTime.compare(dt, cutoff) >= 0) break;
      results.push(dt);
    }

    // Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
    expect(results.length).toBe(4);
  });
});

// =============================================================================
// Iterator Protocol Tests
// =============================================================================

describe("iterator protocol", () => {
  it("occurrences returns iterable", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const iter = schedule.occurrences(from);

    // Check it's iterable via Symbol.iterator
    expect(typeof iter[Symbol.iterator]).toBe("function");
  });

  it("between returns iterable", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
    const to = parseZoned("2026-02-05T00:00:00+00:00[UTC]");

    const iter = schedule.between(from, to);

    expect(typeof iter[Symbol.iterator]).toBe("function");
  });

  it("works with Array.from", () => {
    const schedule = Schedule.parse("every day at 09:00 until 2026-02-05 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const results = Array.from(schedule.occurrences(from));

    expect(results.length).toBe(5); // Feb 1-5
    expect(results.every((dt) => dt instanceof Temporal.ZonedDateTime)).toBe(true);
  });

  it("works with spread operator", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
    const to = parseZoned("2026-02-05T00:00:00+00:00[UTC]");

    const results = [...schedule.between(from, to)];

    expect(results.length).toBe(4); // Feb 1,2,3,4 at 09:00
    expect(results[0].day).toBe(1);
  });
});

// =============================================================================
// For...of Patterns
// =============================================================================

describe("for...of patterns", () => {
  it("occurrences for...of with break", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    let count = 0;
    for (const dt of schedule.occurrences(from)) {
      count++;
      if (dt.day >= 5) break;
    }

    expect(count).toBe(5);
  });

  it("between for...of loop", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");
    const to = parseZoned("2026-02-03T23:59:00+00:00[UTC]");

    const days: number[] = [];
    for (const dt of schedule.between(from, to)) {
      days.push(dt.day);
    }

    expect(days).toEqual([1, 2, 3]);
  });
});

// =============================================================================
// Edge Cases
// =============================================================================

describe("edge cases", () => {
  it("occurrences empty when past until", () => {
    const schedule = Schedule.parse("every day at 09:00 until 2026-01-01 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const results = [...schedule.occurrences(from)];

    expect(results.length).toBe(0);
  });

  it("between empty range", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T12:00:00+00:00[UTC]");
    const to = parseZoned("2026-02-01T13:00:00+00:00[UTC]");

    const results = [...schedule.between(from, to)];

    expect(results.length).toBe(0);
  });

  it("occurrences single date terminates", () => {
    const schedule = Schedule.parse("on 2026-02-14 at 14:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    // Request many but should only get 1
    let count = 0;
    for (const dt of schedule.occurrences(from)) {
      count++;
      if (count >= 100) break;
    }

    expect(count).toBe(1);
  });
});

// =============================================================================
// Timezone Handling
// =============================================================================

describe("timezone handling", () => {
  it("occurrences preserves timezone", () => {
    const schedule = Schedule.parse("every day at 09:00 in America/New_York");
    const from = parseZoned("2026-02-01T00:00:00-05:00[America/New_York]");

    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of schedule.occurrences(from)) {
      results.push(dt);
      if (results.length >= 3) break;
    }

    for (const dt of results) {
      expect(dt.timeZoneId).toBe("America/New_York");
    }
  });

  it("between handles DST transition", () => {
    // March 8, 2026 is DST spring forward in America/New_York
    // 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
    const schedule = Schedule.parse("every day at 02:30 in America/New_York");
    const from = parseZoned("2026-03-07T00:00:00-05:00[America/New_York]");
    const to = parseZoned("2026-03-10T00:00:00-04:00[America/New_York]");

    const results = [...schedule.between(from, to)];

    // Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
    expect(results.length).toBe(3);
    expect(results[0].hour).toBe(2); // Mar 7 02:30
    expect(results[1].hour).toBe(3); // Mar 8 03:30 (shifted due to DST)
    expect(results[2].hour).toBe(2); // Mar 9 02:30
  });
});

// =============================================================================
// Multiple Times Per Day
// =============================================================================

describe("multiple times per day", () => {
  it("occurrences multiple times per day", () => {
    const schedule = Schedule.parse("every day at 09:00, 12:00, 17:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const results: Temporal.ZonedDateTime[] = [];
    for (const dt of schedule.occurrences(from)) {
      results.push(dt);
      if (results.length >= 9) break; // 3 days worth
    }

    expect(results.length).toBe(9);
    // First day: 09:00, 12:00, 17:00
    expect(results[0].hour).toBe(9);
    expect(results[1].hour).toBe(12);
    expect(results[2].hour).toBe(17);
  });
});

// =============================================================================
// Manual Iterator Usage
// =============================================================================

describe("manual iterator usage", () => {
  it("manual next() calls", () => {
    const schedule = Schedule.parse("every day at 09:00 in UTC");
    const from = parseZoned("2026-02-01T00:00:00+00:00[UTC]");

    const iterable = schedule.occurrences(from);
    const iterator = iterable[Symbol.iterator]();

    const first = iterator.next();
    expect(first.done).toBe(false);
    expect(first.value?.day).toBe(1);

    const second = iterator.next();
    expect(second.done).toBe(false);
    expect(second.value?.day).toBe(2);

    const third = iterator.next();
    expect(third.done).toBe(false);
    expect(third.value?.day).toBe(3);
  });
});
