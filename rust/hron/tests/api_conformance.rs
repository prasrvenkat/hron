//! API conformance test — verifies Rust exposes all methods from spec/api.json.
//!
//! This is a compile-time + runtime check: if any method is missing, the code
//! won't compile. The runtime assertions verify return types.

use hron::Schedule;

#[test]
fn static_parse() {
    let result = Schedule::parse("every day at 09:00");
    assert!(result.is_ok());
}

#[test]
fn static_from_cron() {
    let result = Schedule::from_cron("0 9 * * *");
    assert!(result.is_ok());
}

#[test]
fn static_validate() {
    assert!(Schedule::validate("every day at 09:00"));
    assert!(!Schedule::validate("not a schedule"));
}

#[test]
fn instance_next_from() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
    let result: Option<jiff::Zoned> = schedule.next_from(&now).unwrap();
    assert!(result.is_some());
}

#[test]
fn instance_next_n_from() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let now: jiff::Zoned = "2026-02-06T12:00:00+00:00[UTC]".parse().unwrap();
    let results: Vec<jiff::Zoned> = schedule.next_n_from(&now, 3).unwrap();
    assert_eq!(results.len(), 3);
}

#[test]
fn instance_matches() {
    let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    let dt: jiff::Zoned = "2026-02-07T09:00:00+00:00[UTC]".parse().unwrap();
    let result: bool = schedule.matches(&dt).unwrap();
    assert!(result);
}

#[test]
fn instance_to_cron() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let result: Result<String, _> = schedule.to_cron();
    assert!(result.is_ok());
}

#[test]
fn instance_to_string() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let result: String = schedule.to_string();
    assert_eq!(result, "every day at 09:00");
}

#[test]
fn getter_timezone_none() {
    let schedule = Schedule::parse("every day at 09:00").unwrap();
    let tz: Option<&str> = schedule.timezone();
    assert!(tz.is_none());
}

#[test]
fn getter_timezone_some() {
    let schedule = Schedule::parse("every day at 09:00 in America/New_York").unwrap();
    let tz: Option<&str> = schedule.timezone();
    assert_eq!(tz, Some("America/New_York"));
}

/// Verify that the spec file is readable and contains expected structure.
#[test]
fn spec_api_json_is_valid() {
    let spec_str = include_str!("../../../spec/api.json");
    let spec: serde_json::Value = serde_json::from_str(spec_str).expect("valid JSON");

    // Verify all static methods listed in spec are covered
    let static_methods: Vec<&str> = spec["schedule"]["staticMethods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["name"].as_str().unwrap())
        .collect();
    assert!(static_methods.contains(&"parse"));
    assert!(static_methods.contains(&"fromCron"));
    assert!(static_methods.contains(&"validate"));

    // Verify all instance methods listed in spec are covered
    let instance_methods: Vec<&str> = spec["schedule"]["instanceMethods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["name"].as_str().unwrap())
        .collect();
    assert!(instance_methods.contains(&"nextFrom"));
    assert!(instance_methods.contains(&"nextNFrom"));
    assert!(instance_methods.contains(&"matches"));
    assert!(instance_methods.contains(&"toCron"));
    assert!(instance_methods.contains(&"toString"));

    // Verify all getters listed in spec are covered
    let getters: Vec<&str> = spec["schedule"]["getters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|g| g["name"].as_str().unwrap())
        .collect();
    assert!(getters.contains(&"timezone"));
}
