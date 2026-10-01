use super::*;
use crate::parser::parse;

fn fixed_now() -> Zoned {
    let date = Date::new(2026, 2, 6).unwrap();
    let time = Time::new(12, 0, 0, 0).unwrap();
    date.to_datetime(time).to_zoned(TimeZone::UTC).unwrap()
}

#[test]
fn interval_slots_with_a_step_longer_than_the_day() {
    let (from, to) = (
        TimeOfDay { hour: 0, minute: 0 },
        TimeOfDay {
            hour: 23,
            minute: 59,
        },
    );
    assert_eq!(
        interval_slots(u32::MAX, IntervalUnit::Hours, &from, &to),
        vec![0]
    );
}

#[test]
fn matches_drops_seconds_on_the_schedule_wall_clock() {
    // Monrovia kept -00:44:30 until 1972, so 09:00 there is 09:44:30 UTC;
    // dropping UTC seconds would test 08:59:30 local instead.
    let s = parse("every day at 09:00 in Africa/Monrovia").unwrap();
    let at_nine: Zoned = "1960-06-01T09:44:30+00:00[UTC]".parse().unwrap();
    assert!(matches(&s, &at_nine).unwrap());
}

#[test]
fn occurrences_end_after_an_error() {
    // Parse rejects unknown zones; only the builder can set one.
    let s = parse("every day at 09:00")
        .unwrap()
        .with_timezone("Invalid/Zone");
    let mut occurrences = Occurrences::new(&s, fixed_now());
    assert!(matches!(occurrences.next(), Some(Err(_))));
    assert!(occurrences.next().is_none());
}

#[test]
fn next_every_day() {
    let s = parse("every day at 09:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 2, 7).unwrap());
    assert_eq!(next.time().hour(), 9);
}

#[test]
fn next_every_weekday() {
    let s = parse("every weekday at 9:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    // 2026-02-06 is a Friday, time already passed at 12:00
    assert_eq!(next.date(), Date::new(2026, 2, 9).unwrap());
}

#[test]
fn next_weekend() {
    let s = parse("every weekend at 10:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    // 2026-02-07 is Saturday
    assert_eq!(next.date(), Date::new(2026, 2, 7).unwrap());
}

#[test]
fn next_interval() {
    let s = parse("every 45 min from 09:00 to 17:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.time().hour(), 12);
    assert_eq!(next.time().minute(), 45);
}

#[test]
fn next_month_on_day() {
    let s = parse("every month on the 1st at 9:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 3, 1).unwrap());
}

#[test]
fn next_month_last_day() {
    let s = parse("every month on the last day at 17:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 2, 28).unwrap());
}

#[test]
fn next_ordinal_first_monday() {
    let s = parse("every month on the first monday at 10:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    // First Monday of March 2026 = March 2
    assert_eq!(next.date(), Date::new(2026, 3, 2).unwrap());
}

#[test]
fn next_single_date_iso() {
    let s = parse("on 2026-03-15 at 14:30 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 3, 15).unwrap());
    assert_eq!(next.time().hour(), 14);
    assert_eq!(next.time().minute(), 30);
}

#[test]
fn next_single_date_named() {
    let s = parse("on feb 14 at 9:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 2, 14).unwrap());
}

#[test]
fn next_n() {
    let s = parse("every day at 09:00 in UTC").unwrap();
    let now = fixed_now();
    let results = next_n_from(&s, &now, 3).unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0].date(), Date::new(2026, 2, 7).unwrap());
    assert_eq!(results[1].date(), Date::new(2026, 2, 8).unwrap());
    assert_eq!(results[2].date(), Date::new(2026, 2, 9).unwrap());
}

#[test]
fn iso_date_in_past() {
    let s = parse("on 2020-01-01 at 00:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap();
    assert!(next.is_none());
}

#[test]
fn month_skip_31() {
    let s = parse("every month on the 31st at 09:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 3, 31).unwrap());
}

#[test]
fn next_year_repeat_date() {
    let s = parse("every year on dec 25 at 00:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 12, 25).unwrap());
}

#[test]
fn next_year_repeat_ordinal_weekday() {
    let s = parse("every year on the first monday of march at 10:00 in UTC").unwrap();
    let now = fixed_now();
    let next = next_from(&s, &now).unwrap().unwrap();
    assert_eq!(next.date(), Date::new(2026, 3, 2).unwrap());
}

#[test]
fn except_skips_holiday() {
    let s = parse("every weekday at 09:00 except dec 25, jan 1 in UTC").unwrap();
    let now = Date::new(2026, 12, 24)
        .unwrap()
        .to_datetime(Time::new(20, 0, 0, 0).unwrap())
        .to_zoned(TimeZone::UTC)
        .unwrap();
    let next = next_from(&s, &now).unwrap().unwrap();
    // Dec 25 is Friday but excepted, so next = Dec 28 (Monday)
    assert_eq!(next.date(), Date::new(2026, 12, 28).unwrap());
}

#[test]
fn until_limits_results() {
    let s = parse("every day at 09:00 until 2026-02-10 in UTC").unwrap();
    let now = fixed_now();
    let results = next_n_from(&s, &now, 10).unwrap();
    assert_eq!(results.len(), 4);
    assert_eq!(
        results.last().unwrap().date(),
        Date::new(2026, 2, 10).unwrap()
    );
}

#[test]
fn no_offset_change_in_tzdb_exceeds_a_day() {
    // MAX_SHIFT_DAYS and MAX_OVERLAP_DAYS rest on this.
    let end: Timestamp = "2100-01-01T00:00:00Z".parse().unwrap();
    for name in jiff::tz::db().available() {
        let zone = TimeZone::get(name.as_str()).unwrap();
        let mut before = zone.to_offset(Timestamp::MIN);
        for transition in zone.following(Timestamp::MIN) {
            if transition.timestamp() > end {
                break;
            }
            let change = (transition.offset().seconds() - before.seconds()).abs();
            assert!(
                change <= 24 * 60 * 60,
                "{} changes its offset by {change}s at {}",
                name.as_str(),
                transition.timestamp()
            );
            before = transition.offset();
        }
    }
}

#[test]
fn slot_keys_never_decrease_across_gaps_and_overlaps() {
    for (zone, day) in [
        ("America/New_York", "2026-03-08"),
        ("America/New_York", "2026-11-01"),
        ("America/Santiago", "2026-09-06"),
        ("America/Santiago", "2026-04-05"),
        ("Pacific/Apia", "2011-12-30"),
    ] {
        let zone = TimeZone::get(zone).unwrap();
        let date: Date = day.parse().unwrap();
        let mut last: Option<Timestamp> = None;
        for date in [date.yesterday().unwrap(), date, date.tomorrow().unwrap()] {
            for minute in 0..24 * 60 {
                let slot = wall_clock::slot_on(date, minute, &zone);
                if let Some(instant) = &slot.instant {
                    assert_eq!(slot.key, instant.timestamp());
                }
                assert!(last.is_none_or(|last| slot.key >= last), "{date} {minute}");
                last = Some(slot.key);
            }
        }
    }
}

#[test]
fn a_slot_in_a_gap_has_no_instant_and_sits_where_the_gap_ends() {
    let zone = TimeZone::get("America/New_York").unwrap();
    let slot = wall_clock::slot_on("2026-03-08".parse().unwrap(), 2 * 60 + 30, &zone);
    assert!(slot.instant.is_none());
    assert_eq!(
        slot.key,
        "2026-03-08T07:00:00Z".parse::<Timestamp>().unwrap()
    );
}
