use hron::Schedule;
use jiff::{tz::TimeZone, Zoned};

fn parse_zoned(s: &str) -> Zoned {
    s.parse().expect("valid zoned datetime")
}

#[test]
fn occurrences_is_lazy() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let iter = schedule.occurrences(&from);

    let first: Vec<_> = iter.take(1).collect();
    assert_eq!(first.len(), 1);
}

#[test]
fn between_is_lazy() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-12-31T23:59:00+00:00[UTC]");

    let iter = schedule.between(&from, &to);

    let first_three: Vec<_> = iter.take(3).collect();
    assert_eq!(first_three.len(), 3);
}

#[test]
fn occurrences_early_termination_with_take() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.occurrences(&from).take(5).collect();

    assert_eq!(results.len(), 5);
}

#[test]
fn occurrences_early_termination_with_take_while() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let cutoff = parse_zoned("2026-02-05T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule
        .occurrences(&from)
        .take_while(|dt| *dt < cutoff)
        .collect();

    assert_eq!(results.len(), 4);
}

#[test]
fn occurrences_early_termination_with_find() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let saturday = schedule
        .occurrences(&from)
        .find(|dt| dt.weekday().to_sunday_zero_offset() == 6)
        .unwrap();

    // Feb 7, 2026 is a Saturday
    assert_eq!(saturday.date().day(), 7);
}

#[test]
fn occurrences_works_with_filter() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let weekends: Vec<_> = schedule
        .occurrences(&from)
        .take(14)
        .filter(|dt| {
            let dow = dt.weekday().to_sunday_zero_offset();
            dow == 0 || dow == 6
        })
        .collect();

    assert_eq!(weekends.len(), 4);
}

#[test]
fn occurrences_works_with_map() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let days: Vec<i8> = schedule
        .occurrences(&from)
        .take(5)
        .map(|dt| dt.date().day())
        .collect();

    assert_eq!(days, vec![1, 2, 3, 4, 5]);
}

#[test]
fn occurrences_works_with_enumerate() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let enumerated: Vec<_> = schedule.occurrences(&from).take(3).enumerate().collect();

    assert_eq!(enumerated.len(), 3);
    assert_eq!(enumerated[0].0, 0);
    assert_eq!(enumerated[1].0, 1);
    assert_eq!(enumerated[2].0, 2);
}

#[test]
fn occurrences_works_with_skip() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.occurrences(&from).skip(5).take(3).collect();

    assert_eq!(results.len(), 3);
    assert_eq!(results[0].date().day(), 6);
    assert_eq!(results[1].date().day(), 7);
    assert_eq!(results[2].date().day(), 8);
}

#[test]
fn between_works_with_count() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-10T23:59:00+00:00[UTC]");

    let count = schedule.between(&from, &to).count();

    assert_eq!(count, 10);
}

#[test]
fn between_works_with_last() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-10T23:59:00+00:00[UTC]");

    let last = schedule.between(&from, &to).last().unwrap();

    assert_eq!(last.date().day(), 10);
}

#[test]
fn occurrences_collect_to_vec() {
    let schedule = Schedule::parse("every day at 09:00 until 2026-02-05 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<Zoned> = schedule.occurrences(&from).collect();

    assert_eq!(results.len(), 5);
}

#[test]
fn between_collect_to_vec() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-07T23:59:00+00:00[UTC]");

    let results: Vec<Zoned> = schedule.between(&from, &to).collect();

    assert_eq!(results.len(), 7);
}

#[test]
fn occurrences_for_loop_with_break() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let mut count = 0;
    for dt in schedule.occurrences(&from) {
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
    for dt in schedule.between(&from, &to) {
        days.push(dt.date().day());
    }

    assert_eq!(days, vec![1, 2, 3]);
}

#[test]
fn occurrences_empty_when_past_until() {
    let schedule = Schedule::parse("every day at 09:00 until 2026-01-01 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.occurrences(&from).take(10).collect();

    assert!(results.is_empty());
}

#[test]
fn between_empty_range() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T12:00:00+00:00[UTC]");
    let to = parse_zoned("2026-02-01T13:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.between(&from, &to).collect();

    assert!(results.is_empty());
}

#[test]
fn occurrences_single_date_terminates() {
    let schedule = Schedule::parse("on 2026-02-14 at 14:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.occurrences(&from).take(100).collect();

    assert_eq!(results.len(), 1);
}

#[test]
fn occurrences_preserves_timezone() {
    let schedule = Schedule::parse("every day at 09:00 in America/New_York").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00-05:00[America/New_York]");

    let results: Vec<_> = schedule.occurrences(&from).take(3).collect();

    for dt in &results {
        assert_eq!(dt.time_zone(), &TimeZone::get("America/New_York").unwrap());
    }
}

#[test]
fn between_handles_dst_transition() {
    // March 8, 2026 springs forward in New York, so 02:30 that day shifts to 03:30.
    let schedule = Schedule::parse("every day at 02:30 in America/New_York").unwrap();
    let from = parse_zoned("2026-03-07T00:00:00-05:00[America/New_York]");
    let to = parse_zoned("2026-03-10T00:00:00-04:00[America/New_York]");

    let results: Vec<_> = schedule.between(&from, &to).collect();

    assert_eq!(results.len(), 3);
    assert_eq!(results[0].time().hour(), 2);
    assert_eq!(results[1].time().hour(), 3);
    assert_eq!(results[2].time().hour(), 2);
}

#[test]
fn occurrences_multiple_times_per_day() {
    let schedule = Schedule::parse("every day at 09:00, 12:00, 17:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let results: Vec<_> = schedule.occurrences(&from).take(9).collect();

    assert_eq!(results.len(), 9);
    assert_eq!(results[0].time().hour(), 9);
    assert_eq!(results[1].time().hour(), 12);
    assert_eq!(results[2].time().hour(), 17);
}

#[test]
fn complex_iterator_chain() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let from = parse_zoned("2026-02-01T00:00:00+00:00[UTC]");

    let weekday_days: Vec<i8> = schedule
        .occurrences(&from)
        .take(14)
        .filter(|dt| {
            let dow = dt.weekday().to_sunday_zero_offset();
            (1..=5).contains(&dow)
        })
        .take(5)
        .map(|dt| dt.date().day())
        .collect();

    // Feb 2026: 2,3,4,5,6 are Mon-Fri
    assert_eq!(weekday_days, vec![2, 3, 4, 5, 6]);
}
