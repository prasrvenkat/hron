//! Iterator-specific tests for `occurrences()` and `between()` methods.
//!
//! These tests verify Rust-specific iterator behavior beyond conformance tests:
//! - Laziness (iterators don't evaluate eagerly)
//! - Early termination
//! - Error propagation
//! - Integration with std::iter combinators
//! - Memory efficiency patterns

use hron::Schedule;
use jiff::{tz::TimeZone, Zoned};

fn parse_zoned(s: &str) -> Zoned {
    s.parse().expect("valid zoned datetime")
}

// =============================================================================
// Laziness Tests
// =============================================================================

#[test]
fn occurrences_is_lazy() {
    // An unbounded schedule should not hang or OOM when creating the iterator
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Creating the iterator should be instant (lazy)
    let iter = schedule.occurrences(&from);

    // Taking just 1 should work without evaluating the rest
    let first: Vec<_> = iter.take(1).collect::<Result<_, _>>().unwrap();
    assert_eq!(first.len(), 1);
}

#[test]
fn between_is_lazy() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-12-31T23:59:00+00:00[UTC]");

    // Creating the iterator should be instant
    let iter = schedule.between(&from, &to);

    // Taking just 3 should not evaluate all ~330 days
    let first_three: Vec<_> = iter.take(3).collect::<Result<_, _>>().unwrap();
    assert_eq!(first_three.len(), 3);
}

// =============================================================================
// Early Termination Tests
// =============================================================================

#[test]
fn occurrences_early_termination_with_take() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take(5)
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 5);
}

#[test]
fn occurrences_early_termination_with_take_while() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let cutoff = parse_zoned("2026-02-05T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take_while(|r| match r {
            Ok(dt) => dt < &cutoff,
            Err(_) => false,
        })
        .collect::<Result<_, _>>()
        .unwrap();

    // Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
    assert_eq!(results.len(), 4);
}

#[test]
fn occurrences_early_termination_with_find() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Find the first Saturday occurrence
    let saturday = schedule
        .occurrences(&from)
        .find(|r| match r {
            Ok(dt) => dt.weekday().to_sunday_zero_offset() == 6, // Saturday
            Err(_) => false,
        })
        .unwrap()
        .unwrap();

    // Feb 7, 2026 is a Saturday
    assert_eq!(saturday.date().day(), 7);
}

// =============================================================================
// Iterator Combinator Tests
// =============================================================================

#[test]
fn occurrences_works_with_filter() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Filter to only weekends
    let weekends: Vec<_> = schedule
        .occurrences(&from)
        .take(14) // Two weeks
        .filter(|r| match r {
            Ok(dt) => {
                let dow = dt.weekday().to_sunday_zero_offset();
                dow == 0 || dow == 6 // Sunday or Saturday
            }
            Err(_) => false,
        })
        .collect::<Result<_, _>>()
        .unwrap();

    // 2 weekends in 2 weeks = 4 days
    assert_eq!(weekends.len(), 4);
}

#[test]
fn occurrences_works_with_map() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Map to just the day number
    let days: Vec<i8> = schedule
        .occurrences(&from)
        .take(5)
        .map(|r| r.map(|dt| dt.date().day()))
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(days, vec![1, 2, 3, 4, 5]);
}

#[test]
fn occurrences_works_with_enumerate() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let enumerated: Vec<_> = schedule
        .occurrences(&from)
        .take(3)
        .enumerate()
        .collect();

    assert_eq!(enumerated.len(), 3);
    assert_eq!(enumerated[0].0, 0);
    assert_eq!(enumerated[1].0, 1);
    assert_eq!(enumerated[2].0, 2);
}

#[test]
fn occurrences_works_with_skip() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Skip first 5, take next 3
    let results: Vec<_> = schedule
        .occurrences(&from)
        .skip(5)
        .take(3)
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 3);
    // Should be Feb 6, 7, 8
    assert_eq!(results[0].date().day(), 6);
    assert_eq!(results[1].date().day(), 7);
    assert_eq!(results[2].date().day(), 8);
}

#[test]
fn between_works_with_count() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-10T23:59:00+00:00[UTC]");

    // Count occurrences in range
    let count = schedule
        .between(&from, &to)
        .filter(|r| r.is_ok())
        .count();

    // Feb 1-10 inclusive = 10 days
    assert_eq!(count, 10);
}

#[test]
fn between_works_with_last() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-10T23:59:00+00:00[UTC]");

    let last = schedule
        .between(&from, &to)
        .last()
        .unwrap()
        .unwrap();

    assert_eq!(last.date().day(), 10);
}

// =============================================================================
// Collect Patterns
// =============================================================================

#[test]
fn occurrences_collect_to_vec() {
    let schedule = Schedule::parse("every day at 09:00 until 2026-02-05 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<Zoned> = schedule
        .occurrences(&from)
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 5); // Feb 1-5
}

#[test]
fn between_collect_to_vec() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-07T23:59:00+00:00[UTC]");

    let results: Vec<Zoned> = schedule
        .between(&from, &to)
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 7);
}

// =============================================================================
// For Loop Patterns
// =============================================================================

#[test]
fn occurrences_for_loop_with_break() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let mut count = 0;
    for result in schedule.occurrences(&from) {
        let dt = result.unwrap();
        count += 1;
        if dt.date().day() >= 5 {
            break;
        }
    }

    assert_eq!(count, 5);
}

#[test]
fn between_for_loop() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-03T23:59:00+00:00[UTC]");

    let mut days = Vec::new();
    for result in schedule.between(&from, &to) {
        let dt = result.unwrap();
        days.push(dt.date().day());
    }

    assert_eq!(days, vec![1, 2, 3]);
}

// =============================================================================
// Edge Cases
// =============================================================================

#[test]
fn occurrences_empty_when_past_until() {
    let schedule = Schedule::parse("every day at 09:00 until 2026-01-01 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take(10)
        .collect::<Result<_, _>>()
        .unwrap();

    assert!(results.is_empty());
}

#[test]
fn between_empty_range() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T12:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-01T13:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .between(&from, &to)
        .collect::<Result<_, _>>()
        .unwrap();

    assert!(results.is_empty());
}

#[test]
fn occurrences_single_date_terminates() {
    let schedule = Schedule::parse("on 2026-02-14 at 14:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take(100) // Request many but should only get 1
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 1);
}

// =============================================================================
// Timezone Handling
// =============================================================================

#[test]
fn occurrences_preserves_timezone() {
    let schedule = Schedule::parse("every day at 09:00 in America/New_York").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00-05:00[America/New_York]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take(3)
        .collect::<Result<_, _>>()
        .unwrap();

    for dt in &results {
        assert_eq!(dt.time_zone(), &TimeZone::get("America/New_York").unwrap());
    }
}

#[test]
fn between_handles_dst_transition() {
    // March 8, 2026 is DST spring forward in America/New_York
    // 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
    let schedule = Schedule::parse("every day at 02:30 in America/New_York").unwrap();
    let from = parse_zoned("2026-03-07T00:00:00-05:00[America/New_York]");
    let to = parse_zoned("2026-03-10T00:00:00-04:00[America/New_York]");

    let results: Vec<_> = schedule
        .between(&from, &to)
        .collect::<Result<_, _>>()
        .unwrap();

    // Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].time().hour(), 2);  // Mar 7 02:30
    assert_eq!(results[1].time().hour(), 3);  // Mar 8 03:30 (shifted due to DST)
    assert_eq!(results[2].time().hour(), 2);  // Mar 9 02:30
}

// =============================================================================
// Multiple Times Per Day
// =============================================================================

#[test]
fn occurrences_multiple_times_per_day() {
    let schedule = Schedule::parse("every day at 09:00, 12:00, 17:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take(9) // 3 days worth
        .collect::<Result<_, _>>()
        .unwrap();

    assert_eq!(results.len(), 9);
    // First day: 09:00, 12:00, 17:00
    assert_eq!(results[0].time().hour(), 9);
    assert_eq!(results[1].time().hour(), 12);
    assert_eq!(results[2].time().hour(), 17);
}

// =============================================================================
// Chained Operations
// =============================================================================

#[test]
fn complex_iterator_chain() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    // Complex chain: skip weekends, take first 5 weekdays, get their day numbers
    let weekday_days: Vec<i8> = schedule
        .occurrences(&from)
        .take(14) // Two weeks to ensure we have enough
        .filter_map(|r| r.ok())
        .filter(|dt| {
            let dow = dt.weekday().to_sunday_zero_offset();
            dow >= 1 && dow <= 5 // Monday-Friday
        })
        .take(5)
        .map(|dt| dt.date().day())
        .collect();

    // Feb 2026: 2,3,4,5,6 are Mon-Fri
    assert_eq!(weekday_days, vec![2, 3, 4, 5, 6]);
}
