//! spec/README.md, "Supported range" and "Timestamps and counts".

use hron::Schedule;
use jiff::tz::TimeZone;
use jiff::{SignedDuration, Timestamp, Zoned};

fn in_zone(instant: Timestamp, zone: &str) -> Zoned {
    instant.to_zoned(TimeZone::get(zone).unwrap())
}

fn at(s: &str) -> Zoned {
    s.parse().unwrap()
}

fn strings(times: Vec<Zoned>) -> Vec<String> {
    times.iter().map(Zoned::to_string).collect()
}

// Kiritimati is at +14:00 now and Etc/GMT+12 at -12:00, the extremes of local time.
#[test]
fn jiffs_own_limits_find_nothing_and_raise_nothing() {
    let second = SignedDuration::from_secs(1);
    let limits = [
        Timestamp::MIN,
        Timestamp::MIN.checked_add(second).unwrap(),
        Timestamp::MAX.checked_sub(second).unwrap(),
        Timestamp::MAX,
    ];
    let inside = at("2026-02-06T12:00:00+00:00[UTC]");
    for expression in [
        "every day at 09:00",
        "every 1 min from 00:00 to 23:59",
        "every day at 09:00 in Pacific/Kiritimati",
        "every day at 09:00 in Etc/GMT+12",
    ] {
        let schedule = Schedule::parse(expression).unwrap();
        for zone in ["Pacific/Kiritimati", "Etc/GMT+12"] {
            for instant in limits {
                let limit = in_zone(instant, zone);
                let label = format!("'{expression}' at {limit}");
                assert_eq!(schedule.next_from(&limit), None, "{label}");
                assert_eq!(schedule.previous_from(&limit), None, "{label}");
                assert!(!schedule.matches(&limit), "{label}");
                assert_eq!(schedule.next_n_from(&limit, 3), vec![], "{label}");
                assert!(schedule.occurrences(&limit).next().is_none(), "{label}");
                assert!(schedule.between(&limit, &limit).next().is_none(), "{label}");
                let (from, to) = if instant < inside.timestamp() {
                    (limit.clone(), inside.clone())
                } else {
                    (inside.clone(), limit.clone())
                };
                assert!(schedule.between(&from, &to).next().is_none(), "{label}");
            }
        }
    }
}

#[test]
fn results_come_back_in_the_schedule_zone() {
    let schedule = Schedule::parse("every day at 09:00 in America/New_York").unwrap();
    let tokyo = at("2026-02-06T21:00:00+09:00[Asia/Tokyo]");
    let berlin = at("2026-02-07T15:00:00+01:00[Europe/Berlin]");
    let first = "2026-02-06T09:00:00-05:00[America/New_York]";
    let second = "2026-02-07T09:00:00-05:00[America/New_York]";

    assert_eq!(schedule.next_from(&tokyo).unwrap().to_string(), first);
    assert_eq!(
        schedule.previous_from(&tokyo).unwrap().to_string(),
        "2026-02-05T09:00:00-05:00[America/New_York]"
    );
    assert_eq!(strings(schedule.next_n_from(&tokyo, 2)), [first, second]);
    let occurrences = schedule.occurrences(&tokyo).take(2).collect();
    assert_eq!(strings(occurrences), [first, second]);
    let between = schedule.between(&tokyo, &berlin).collect();
    assert_eq!(strings(between), [first, second]);
}

#[test]
fn results_come_back_in_utc_without_a_schedule_zone() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let tokyo = at("2026-02-06T21:00:00+09:00[Asia/Tokyo]");
    let berlin = at("2026-02-07T15:00:00+01:00[Europe/Berlin]");
    let first = "2026-02-07T09:00:00+00:00[UTC]";

    assert_eq!(schedule.next_from(&tokyo).unwrap().to_string(), first);
    assert_eq!(
        schedule.previous_from(&tokyo).unwrap().to_string(),
        "2026-02-06T09:00:00+00:00[UTC]"
    );
    assert_eq!(strings(schedule.next_n_from(&tokyo, 1)), [first]);
    let occurrences = schedule.occurrences(&tokyo).take(1).collect();
    assert_eq!(strings(occurrences), [first]);
    let between = schedule.between(&tokyo, &berlin).collect();
    assert_eq!(strings(between), [first]);
}
