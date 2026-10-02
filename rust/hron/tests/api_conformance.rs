//! spec/api.json's names map to Rust's as its Rust note says.

use hron::ast::{Exception, MonthName, UntilSpec};
use hron::{ErrorKind, Schedule, ScheduleError, ScheduleExpr, ScheduleParts, Span};
use jiff::Zoned;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fmt::Display;
use std::hash::{DefaultHasher, Hash, Hasher};

type Member = (&'static str, &'static str, fn());

const MEMBERS: &[Member] = &[
    ("schedule.staticMethods", "parse", parse),
    ("schedule.staticMethods", "fromCron", from_cron),
    ("schedule.staticMethods", "validate", validate),
    ("schedule.instanceMethods", "nextFrom", next_from),
    ("schedule.instanceMethods", "nextNFrom", next_n_from),
    ("schedule.instanceMethods", "previousFrom", previous_from),
    ("schedule.instanceMethods", "matches", matches),
    ("schedule.instanceMethods", "occurrences", occurrences),
    ("schedule.instanceMethods", "between", between),
    ("schedule.instanceMethods", "toCron", to_cron),
    ("schedule.instanceMethods", "toString", to_string),
    ("schedule.instanceMethods", "equals", equals),
    ("schedule.getters", "timezone", timezone),
    ("schedule.getters", "expression", expression),
    ("schedule.getters", "except", except),
    ("schedule.getters", "until", until),
    ("schedule.getters", "starting", starting),
    ("schedule.getters", "during", during),
    ("error.kinds", "lex", kind_lex),
    ("error.kinds", "parse", kind_parse),
    ("error.kinds", "eval", kind_eval),
    ("error.kinds", "cron", kind_cron),
    ("error.properties", "kind", property_kind),
    ("error.properties", "message", property_message),
    ("error.properties", "span", property_span),
    ("error.properties", "input", property_input),
    ("error.properties", "suggestion", property_suggestion),
    ("error.constructors", "lex", constructor_lex),
    ("error.constructors", "parse", constructor_parse),
    ("error.constructors", "eval", constructor_eval),
    ("error.constructors", "cron", constructor_cron),
    ("error.methods", "displayRich", display_rich),
];

fn api_spec() -> Value {
    serde_json::from_str(include_str!("../../../spec/api.json")).expect("spec/api.json is JSON")
}

/// Every name in every list under `schedule` and `error`, so a list added to
/// api.json is checked too.
fn spec_names(spec: &Value) -> BTreeSet<(String, String)> {
    let mut names = BTreeSet::new();
    for part in ["schedule", "error"] {
        let lists = spec[part].as_object().expect("an object");
        for (list, entries) in lists {
            let Some(entries) = entries.as_array() else {
                continue;
            };
            for entry in entries {
                let name = entry
                    .as_str()
                    .or_else(|| entry["name"].as_str())
                    .expect("a name");
                names.insert((format!("{part}.{list}"), name.to_string()));
            }
        }
    }
    names
}

fn table_names() -> BTreeSet<(String, String)> {
    MEMBERS
        .iter()
        .map(|(list, name, _)| (list.to_string(), name.to_string()))
        .collect()
}

fn unmapped(spec: &Value) -> Vec<(String, String)> {
    spec_names(spec)
        .difference(&table_names())
        .cloned()
        .collect()
}

#[test]
fn maps_every_api_json_name() {
    assert_eq!(unmapped(&api_spec()), vec![]);
}

#[test]
fn maps_nothing_api_json_lacks() {
    let stale: Vec<_> = table_names()
        .difference(&spec_names(&api_spec()))
        .cloned()
        .collect();
    assert_eq!(stale, vec![]);
}

#[test]
fn fails_on_a_name_added_to_api_json() {
    let mut spec = api_spec();
    spec["schedule"]["instanceMethods"]
        .as_array_mut()
        .unwrap()
        .push(json!({ "name": "nextWeekFrom" }));
    spec["error"]["kinds"]
        .as_array_mut()
        .unwrap()
        .push(json!("timeout"));
    spec["schedule"]["properties"] = json!([{ "name": "id" }]);
    assert_eq!(
        unmapped(&spec),
        vec![
            ("error.kinds".to_string(), "timeout".to_string()),
            (
                "schedule.instanceMethods".to_string(),
                "nextWeekFrom".to_string()
            ),
            ("schedule.properties".to_string(), "id".to_string()),
        ]
    );
}

#[test]
fn every_member_behaves_as_api_json_describes() {
    for (list, name, check) in MEMBERS {
        println!("{list}.{name}");
        check();
    }
}

fn now() -> Zoned {
    "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap()
}

fn daily() -> Schedule {
    Schedule::parse("every day at 09:00").unwrap()
}

fn every_clause() -> Schedule {
    Schedule::parse(
        "every day at 09:00 except dec 25, 2026-07-04 until 2027-12-31 starting 2026-01-05 during jan, dec in america/new_york",
    )
    .unwrap()
}

fn hash_of(schedule: &Schedule) -> u64 {
    let mut hasher = DefaultHasher::new();
    schedule.hash(&mut hasher);
    hasher.finish()
}

fn parse() {
    let parse: fn(&str) -> Result<Schedule, ScheduleError> = Schedule::parse;
    assert_eq!(
        parse("every day at 9:00").unwrap().to_string(),
        "every day at 09:00"
    );
}

fn from_cron() {
    let from_cron: fn(&str) -> Result<Schedule, ScheduleError> = Schedule::from_cron;
    assert_eq!(
        from_cron("0 9 * * 1-5").unwrap().to_string(),
        "every weekday at 09:00"
    );
}

fn validate() {
    let validate: fn(&str) -> bool = Schedule::validate;
    assert!(validate("every day at 09:00"));
    assert!(!validate("every day at 09:00 in Nope/Zone"));
}

fn next_from() {
    let next_from: fn(&Schedule, &Zoned) -> Option<Zoned> = Schedule::next_from;
    assert_eq!(
        next_from(&daily(), &now()).unwrap().to_string(),
        "2026-02-07T09:00:00+00:00[UTC]"
    );
}

fn next_n_from() {
    let next_n_from: fn(&Schedule, &Zoned, usize) -> Vec<Zoned> = Schedule::next_n_from;
    assert_eq!(next_n_from(&daily(), &now(), 3).len(), 3);
}

fn previous_from() {
    let previous_from: fn(&Schedule, &Zoned) -> Option<Zoned> = Schedule::previous_from;
    assert_eq!(
        previous_from(&daily(), &now()).unwrap().to_string(),
        "2026-02-06T09:00:00+00:00[UTC]"
    );
}

fn matches() {
    let matches: fn(&Schedule, &Zoned) -> bool = Schedule::matches;
    assert!(matches(
        &daily(),
        &"2026-02-07T09:00:00+00:00[UTC]".parse().unwrap()
    ));
    assert!(!matches(&daily(), &now()));
}

fn occurrences() {
    let schedule = daily();
    let first: Vec<Zoned> = schedule.occurrences(&now()).take(2).collect();
    assert_eq!(
        first.iter().map(Zoned::to_string).collect::<Vec<_>>(),
        [
            "2026-02-07T09:00:00+00:00[UTC]",
            "2026-02-08T09:00:00+00:00[UTC]"
        ]
    );
}

fn between() {
    let schedule = daily();
    let to: Zoned = "2026-02-08T09:00:00+00:00[UTC]".parse().unwrap();
    let found: Vec<Zoned> = schedule.between(&now(), &to).collect();
    assert_eq!(found.len(), 2);
}

fn to_cron() {
    let to_cron: fn(&Schedule) -> Result<String, ScheduleError> = Schedule::to_cron;
    assert_eq!(to_cron(&daily()).unwrap(), "0 9 * * *");
}

fn to_string() {
    fn displays<T: Display>(value: &T) -> String {
        value.to_string()
    }
    assert_eq!(displays(&every_clause()), every_clause().to_string());
    assert_eq!(
        every_clause().to_string(),
        "every day at 09:00 except dec 25, 2026-07-04 until 2027-12-31 starting 2026-01-05 during jan, dec in America/New_York"
    );
}

fn equals() {
    fn equal_with_equal_hashes<T: Eq + Hash>(a: &T, b: &T) -> bool {
        let hash = |value: &T| {
            let mut hasher = DefaultHasher::new();
            value.hash(&mut hasher);
            hasher.finish()
        };
        a == b && hash(a) == hash(b)
    }
    let nine = Schedule::parse("every day at 9:00").unwrap();
    assert!(equal_with_equal_hashes(&nine, &daily()));
    assert_ne!(nine, Schedule::parse("every day at 09:01").unwrap());
}

fn timezone() {
    let timezone: fn(&Schedule) -> Option<&str> = Schedule::timezone;
    assert_eq!(timezone(&every_clause()), Some("America/New_York"));
    assert_eq!(timezone(&daily()), None);
}

fn expression() {
    let expression: fn(&Schedule) -> &ScheduleExpr = Schedule::expression;
    assert!(matches!(
        expression(&daily()),
        ScheduleExpr::DayRepeat { interval: 1, .. }
    ));
}

fn except() {
    let except: fn(&Schedule) -> &[Exception] = Schedule::except;
    assert_eq!(
        except(&every_clause()),
        [
            Exception::Named {
                month: MonthName::December,
                day: 25
            },
            Exception::Iso("2026-07-04".into()),
        ]
    );
    assert_eq!(except(&daily()), []);
}

fn until() {
    let until: fn(&Schedule) -> Option<&UntilSpec> = Schedule::until;
    assert_eq!(
        until(&every_clause()),
        Some(&UntilSpec::Iso("2027-12-31".into()))
    );
    assert_eq!(until(&daily()), None);
}

fn starting() {
    let starting: fn(&Schedule) -> Option<jiff::civil::Date> = Schedule::starting;
    assert_eq!(
        starting(&every_clause()),
        Some(jiff::civil::date(2026, 1, 5))
    );
    assert_eq!(starting(&daily()), None);
}

fn during() {
    let during: fn(&Schedule) -> &[MonthName] = Schedule::during;
    assert_eq!(
        during(&every_clause()),
        [MonthName::January, MonthName::December]
    );
    assert_eq!(during(&daily()), []);
}

fn lex_error() -> ScheduleError {
    Schedule::parse("every day at 09:00 #").unwrap_err()
}

fn parse_error() -> ScheduleError {
    Schedule::parse("every weekday at 09:00 until dec 31").unwrap_err()
}

fn eval_error() -> ScheduleError {
    let mut parts: ScheduleParts = daily().to_parts();
    parts.timezone = Some("EST".into());
    Schedule::from_parts(parts).unwrap_err()
}

fn cron_error() -> ScheduleError {
    Schedule::from_cron("0 9 15 * 1").unwrap_err()
}

fn kind_lex() {
    assert_eq!(lex_error().kind(), ErrorKind::Lex);
}

fn kind_parse() {
    assert_eq!(parse_error().kind(), ErrorKind::Parse);
}

fn kind_eval() {
    assert_eq!(eval_error().kind(), ErrorKind::Eval);
}

fn kind_cron() {
    assert_eq!(cron_error().kind(), ErrorKind::Cron);
}

fn property_kind() {
    let kind: fn(&ScheduleError) -> ErrorKind = ScheduleError::kind;
    assert_eq!(
        [lex_error(), parse_error(), eval_error(), cron_error()].map(|e| kind(&e)),
        [
            ErrorKind::Lex,
            ErrorKind::Parse,
            ErrorKind::Eval,
            ErrorKind::Cron
        ]
    );
}

fn property_message() {
    let message: fn(&ScheduleError) -> &str = ScheduleError::message;
    for error in [lex_error(), parse_error(), eval_error(), cron_error()] {
        assert_eq!(message(&error), error.to_string());
    }
    assert_eq!(
        message(&parse_error()),
        "until dec 31 has no year: add a starting date, or use an ISO date"
    );
}

fn property_span() {
    let span: fn(&ScheduleError) -> Option<Span> = ScheduleError::span;
    assert_eq!(span(&lex_error()), Some(Span::new(19, 20)));
    assert_eq!(span(&parse_error()), Some(Span::new(23, 35)));
    assert_eq!(span(&eval_error()), None);
    assert_eq!(span(&cron_error()), None);
}

fn property_input() {
    let input: fn(&ScheduleError) -> Option<&str> = ScheduleError::input;
    assert_eq!(input(&lex_error()), Some("every day at 09:00 #"));
    assert_eq!(
        input(&parse_error()),
        Some("every weekday at 09:00 until dec 31")
    );
    assert_eq!(input(&eval_error()), None);
    assert_eq!(input(&cron_error()), None);
}

fn property_suggestion() {
    let suggestion: fn(&ScheduleError) -> Option<&str> = ScheduleError::suggestion;
    assert_eq!(
        suggestion(&parse_error()),
        Some("until dec 31 starting YYYY-MM-DD")
    );
    assert_eq!(suggestion(&lex_error()), None);
    assert_eq!(suggestion(&eval_error()), None);
    assert_eq!(suggestion(&cron_error()), None);
}

fn constructor_lex() {
    let error = ScheduleError::lex("unexpected character '#'", Span::new(0, 1), "#");
    assert_eq!(error.kind(), ErrorKind::Lex);
    assert_eq!(error.span(), Some(Span::new(0, 1)));
    assert_eq!(error.input(), Some("#"));
}

fn constructor_parse() {
    let error = ScheduleError::parse("m", Span::new(1, 2), "ab", Some("c".into()));
    assert_eq!(error.kind(), ErrorKind::Parse);
    assert_eq!(error.suggestion(), Some("c"));
}

fn constructor_eval() {
    let error = ScheduleError::eval("m");
    assert_eq!((error.kind(), error.message()), (ErrorKind::Eval, "m"));
}

fn constructor_cron() {
    let error = ScheduleError::cron("m");
    assert_eq!((error.kind(), error.message()), (ErrorKind::Cron, "m"));
}

fn display_rich() {
    let display_rich: fn(&ScheduleError) -> String = ScheduleError::display_rich;
    assert_eq!(
        display_rich(&parse_error()),
        "error: until dec 31 has no year: add a starting date, or use an ISO date\n  every weekday at 09:00 until dec 31\n                         ^^^^^^^^^^^^ try: \"until dec 31 starting YYYY-MM-DD\""
    );
    assert_eq!(
        display_rich(&cron_error()),
        format!("error: {}", cron_error())
    );
}

#[test]
fn equal_schedules_hash_alike_and_compare_lists_in_order_with_duplicates() {
    let parse = |input| Schedule::parse(input).unwrap();
    assert_eq!(hash_of(&parse("every day at 9:00")), hash_of(&daily()));
    assert_ne!(
        parse("every day at 09:00, 17:00"),
        parse("every day at 17:00, 09:00")
    );
    assert_ne!(
        parse("every day at 09:00, 09:00"),
        parse("every day at 09:00")
    );
    assert_ne!(
        parse("every day at 09:00 during jan, feb"),
        parse("every day at 09:00 during feb, jan")
    );
}
