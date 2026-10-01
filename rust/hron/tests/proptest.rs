use hron::Schedule;
use proptest::prelude::*;

fn arb_time() -> impl Strategy<Value = String> {
    (
        0u8..24,
        prop_oneof![Just(0u8), Just(15), Just(30), Just(45)],
    )
        .prop_map(|(h, m)| format!("{:02}:{:02}", h, m))
}

fn arb_time_list() -> impl Strategy<Value = String> {
    prop_oneof![
        arb_time().prop_map(|t| t),
        (arb_time(), arb_time()).prop_map(|(a, b)| format!("{a}, {b}")),
    ]
}

fn arb_day_filter() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("day".to_string()),
        Just("weekday".to_string()),
        Just("weekend".to_string()),
        Just("monday".to_string()),
        Just("mon, wed, fri".to_string()),
        Just("tue, thu".to_string()),
        Just("saturday".to_string()),
    ]
}

fn arb_month() -> impl Strategy<Value = &'static str> {
    prop_oneof![
        Just("jan"),
        Just("feb"),
        Just("mar"),
        Just("apr"),
        Just("may"),
        Just("jun"),
        Just("jul"),
        Just("aug"),
        Just("sep"),
        Just("oct"),
        Just("nov"),
        Just("dec"),
    ]
}

fn arb_ordinal() -> impl Strategy<Value = &'static str> {
    prop_oneof![
        Just("first"),
        Just("second"),
        Just("third"),
        Just("fourth"),
        Just("last"),
    ]
}

fn arb_weekday_name() -> impl Strategy<Value = &'static str> {
    prop_oneof![
        Just("monday"),
        Just("tuesday"),
        Just("wednesday"),
        Just("thursday"),
        Just("friday"),
        Just("saturday"),
        Just("sunday"),
    ]
}

/// All expressions use explicit `in UTC` to make tests deterministic
/// regardless of the machine's system timezone (avoiding DST-gap edge
/// cases in self-consistency checks).
fn arb_hron_expression() -> impl Strategy<Value = String> {
    prop_oneof![
        (arb_day_filter(), arb_time_list()).prop_map(|(d, t)| format!("every {d} at {t} in UTC")),
        (
            prop_oneof![Just(15u32), Just(30), Just(45), Just(60)],
            prop_oneof![Just("min"), Just("hours")]
        )
            .prop_map(|(i, u)| {
                let unit = if i == 1 {
                    if u == "min" {
                        "minute"
                    } else {
                        "hour"
                    }
                } else {
                    u
                };
                format!("every {i} {unit} from 09:00 to 17:00 in UTC")
            }),
        (1u32..5, arb_weekday_name(), arb_time_list())
            .prop_map(|(i, d, t)| format!("every {i} weeks on {d} at {t} in UTC")),
        (
            prop_oneof![Just(1u8), Just(5), Just(10), Just(15), Just(28)],
            arb_time_list()
        )
            .prop_map(|(d, t)| {
                let suffix = match d {
                    1 | 21 | 31 => "st",
                    2 | 22 => "nd",
                    3 | 23 => "rd",
                    _ => "th",
                };
                format!("every month on the {d}{suffix} at {t} in UTC")
            }),
        (arb_ordinal(), arb_weekday_name(), arb_time_list())
            .prop_map(|(o, d, t)| format!("every month on the {o} {d} at {t} in UTC")),
        (arb_month(), 1u8..29, arb_time_list())
            .prop_map(|(m, d, t)| format!("every year on {m} {d} at {t} in UTC")),
        (arb_month(), 1u8..29, arb_time_list())
            .prop_map(|(m, d, t)| format!("on {m} {d} at {t} in UTC")),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(500))]

    #[test]
    fn roundtrip_idempotency(expr in arb_hron_expression()) {
        let schedule = Schedule::parse(&expr).unwrap();
        let displayed = schedule.to_string();
        let reparsed = Schedule::parse(&displayed)
            .unwrap_or_else(|e| panic!("re-parse failed for '{displayed}': {e}"));
        let redisplayed = reparsed.to_string();
        prop_assert_eq!(&displayed, &redisplayed,
            "roundtrip not idempotent: '{}' -> '{}' -> '{}'", expr, displayed, redisplayed);
    }

    #[test]
    fn temporal_ordering(expr in arb_hron_expression()) {
        let schedule = Schedule::parse(&expr).unwrap();
        let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
        if let Ok(Some(next)) = schedule.next_from(&now) {
            prop_assert!(next > now,
                "next_from returned {} which is not after {} for '{}'", next, now, expr);
        }
    }

    #[test]
    fn self_consistency(expr in arb_hron_expression()) {
        let schedule = Schedule::parse(&expr).unwrap();
        let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
        if let Ok(Some(next)) = schedule.next_from(&now) {
            let matches = schedule.matches(&next)
                .unwrap_or_else(|e| panic!("matches error for '{expr}': {e}"));
            prop_assert!(matches,
                "next_from returned {} but matches() is false for '{}'", next, expr);
        }
    }
}
