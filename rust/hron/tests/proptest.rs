use hron::ast::{
    DateSpec, DayFilter, DayOfMonthSpec, Exception, IntervalUnit, MonthName, MonthTarget,
    NearestDirection, OrdinalPosition, TimeOfDay, UntilSpec, Weekday, YearTarget,
};
use hron::{Schedule, ScheduleError, ScheduleExpr, ScheduleParts};
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

// Mostly values that keep the rules, with values just past each limit mixed in,
// so that many parts build and many fail.
fn arb_part_time() -> impl Strategy<Value = TimeOfDay> {
    (
        prop_oneof![19 => 0u8..24, 1 => Just(24u8)],
        prop_oneof![19 => prop_oneof![Just(0u8), Just(30), Just(59)], 1 => Just(60u8)],
    )
        .prop_map(|(hour, minute)| TimeOfDay { hour, minute })
}

fn arb_part_times() -> impl Strategy<Value = Vec<TimeOfDay>> {
    prop_oneof![19 => prop::collection::vec(arb_part_time(), 1..3), 1 => Just(vec![])]
}

fn arb_part_interval() -> impl Strategy<Value = u32> {
    prop_oneof![
        10 => Just(1u32),
        6 => Just(2u32),
        2 => Just(i32::MAX as u32),
        1 => Just(0u32),
        1 => Just(i32::MAX as u32 + 1),
    ]
}

fn arb_part_day() -> impl Strategy<Value = u8> {
    prop_oneof![16 => 1u8..=28, 3 => 29u8..=31, 1 => prop_oneof![Just(0u8), Just(32)]]
}

fn arb_part_weekday() -> impl Strategy<Value = Weekday> {
    (1u8..=7).prop_map(|n| Weekday::from_number(n).unwrap())
}

fn arb_part_weekdays() -> impl Strategy<Value = Vec<Weekday>> {
    prop_oneof![19 => prop::collection::vec(arb_part_weekday(), 1..3), 1 => Just(vec![])]
}

fn arb_part_month() -> impl Strategy<Value = MonthName> {
    prop_oneof![
        Just(MonthName::January),
        Just(MonthName::February),
        Just(MonthName::April)
    ]
}

fn arb_part_day_filter() -> impl Strategy<Value = DayFilter> {
    prop_oneof![
        Just(DayFilter::Every),
        Just(DayFilter::Weekday),
        Just(DayFilter::Weekend),
        arb_part_weekdays().prop_map(DayFilter::Days),
    ]
}

fn arb_part_iso() -> impl Strategy<Value = String> {
    prop_oneof![
        8 => Just("2026-02-28".to_string()),
        8 => Just("2028-02-29".to_string()),
        1 => Just("2026-02-29".to_string()),
        1 => Just("0000-01-01".to_string()),
        1 => Just("20260206".to_string()),
    ]
}

fn arb_part_expression() -> impl Strategy<Value = ScheduleExpr> {
    let day_of_month = prop_oneof![
        8 => arb_part_day().prop_map(DayOfMonthSpec::Single),
        8 => (arb_part_day(), arb_part_day()).prop_map(|(a, b)| DayOfMonthSpec::Range(a.min(b), a.max(b))),
        1 => (arb_part_day(), arb_part_day()).prop_map(|(a, b)| DayOfMonthSpec::Range(a, b)),
    ];
    let month_target = prop_oneof![
        prop_oneof![
            19 => prop::collection::vec(day_of_month, 1..3),
            1 => Just(vec![]),
        ]
        .prop_map(MonthTarget::Days),
        Just(MonthTarget::LastDay),
        Just(MonthTarget::LastWeekday),
        (
            arb_part_day(),
            prop_oneof![Just(None), Just(Some(NearestDirection::Next))]
        )
            .prop_map(|(day, direction)| MonthTarget::NearestWeekday { day, direction }),
        arb_part_weekday().prop_map(|weekday| MonthTarget::OrdinalWeekday {
            ordinal: OrdinalPosition::Last,
            weekday
        }),
    ];
    let year_target = prop_oneof![
        (arb_part_month(), arb_part_day()).prop_map(|(month, day)| YearTarget::Date { month, day }),
        (arb_part_month(), arb_part_day())
            .prop_map(|(month, day)| YearTarget::DayOfMonth { day, month }),
        (arb_part_month(), arb_part_weekday()).prop_map(|(month, weekday)| {
            YearTarget::OrdinalWeekday {
                ordinal: OrdinalPosition::Fifth,
                weekday,
                month,
            }
        }),
        arb_part_month().prop_map(|month| YearTarget::LastWeekday { month }),
    ];
    let date = prop_oneof![
        (arb_part_month(), arb_part_day()).prop_map(|(month, day)| DateSpec::Named { month, day }),
        arb_part_iso().prop_map(DateSpec::Iso),
    ];
    prop_oneof![
        (
            arb_part_interval(),
            prop_oneof![Just(IntervalUnit::Minutes), Just(IntervalUnit::Hours)],
            arb_part_time(),
            arb_part_time(),
            prop::option::of(arb_part_day_filter())
        )
            .prop_map(|(interval, unit, from, to, day_filter)| {
                ScheduleExpr::IntervalRepeat {
                    interval,
                    unit,
                    from,
                    to,
                    day_filter,
                }
            }),
        (arb_part_interval(), arb_part_day_filter(), arb_part_times()).prop_map(
            |(interval, days, times)| ScheduleExpr::DayRepeat {
                interval,
                days,
                times
            }
        ),
        (arb_part_interval(), arb_part_weekdays(), arb_part_times()).prop_map(
            |(interval, days, times)| ScheduleExpr::WeekRepeat {
                interval,
                days,
                times
            }
        ),
        (arb_part_interval(), month_target, arb_part_times()).prop_map(
            |(interval, target, times)| ScheduleExpr::MonthRepeat {
                interval,
                target,
                times
            }
        ),
        (date, arb_part_times()).prop_map(|(date, times)| ScheduleExpr::SingleDate { date, times }),
        (arb_part_interval(), year_target, arb_part_times()).prop_map(
            |(interval, target, times)| ScheduleExpr::YearRepeat {
                interval,
                target,
                times
            }
        ),
    ]
}

fn arb_parts() -> impl Strategy<Value = ScheduleParts> {
    (
        arb_part_expression(),
        prop::option::of(prop_oneof![
            9 => Just("utc".to_string()),
            9 => Just("america/new_york".to_string()),
            1 => Just("EST".to_string()),
        ]),
        prop::collection::vec(
            prop_oneof![
                (arb_part_month(), arb_part_day())
                    .prop_map(|(month, day)| Exception::Named { month, day }),
                arb_part_iso().prop_map(Exception::Iso),
            ],
            0..2,
        ),
        prop::option::of(prop_oneof![
            (arb_part_month(), arb_part_day())
                .prop_map(|(month, day)| UntilSpec::Named { month, day }),
            arb_part_iso().prop_map(UntilSpec::Iso),
        ]),
        prop::option::of(prop_oneof![
            19 => Just(jiff::civil::date(2026, 2, 6)),
            1 => Just(jiff::civil::date(0, 1, 1)),
        ]),
        prop::collection::vec(arb_part_month(), 0..2),
    )
        .prop_map(
            |(expression, timezone, except, until, starting, during)| ScheduleParts {
                expression,
                timezone,
                except,
                until,
                starting,
                during,
            },
        )
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2000))]

    /// spec/README.md, "Schedules built in code".
    #[test]
    fn built_schedules_keep_the_promises_of_parsed_ones(parts in arb_parts()) {
        let Ok(schedule) = Schedule::from_parts(parts) else {
            return Ok(());
        };
        let text = schedule.to_string();
        let parsed = Schedule::parse(&text)
            .unwrap_or_else(|e| panic!("'{text}' does not parse: {e}"));
        prop_assert_eq!(&parsed, &schedule, "'{}' parses to a different schedule", text);
        if let Err(error) = schedule.to_cron() {
            prop_assert!(matches!(error, ScheduleError::Cron { .. }), "{error:?}");
        }
        let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
        if let Some(next) = schedule.next_from(&now) {
            prop_assert!(schedule.matches(&next), "'{}' at {}", text, next);
        }
        schedule.previous_from(&now);
    }
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
        if let Some(next) = schedule.next_from(&now) {
            prop_assert!(next > now,
                "next_from returned {} which is not after {} for '{}'", next, now, expr);
        }
    }

    #[test]
    fn self_consistency(expr in arb_hron_expression()) {
        let schedule = Schedule::parse(&expr).unwrap();
        let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
        if let Some(next) = schedule.next_from(&now) {
            prop_assert!(schedule.matches(&next),
                "next_from returned {} but matches() is false for '{}'", next, expr);
        }
    }
}
