use hron::{Schedule, ScheduleError, ScheduleParts};
use serde_json::Value;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::LazyLock;

static SPEC: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../../spec/tests.json"))
        .expect("spec/tests.json is invalid JSON")
});

static BUILD: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../../spec/build.json"))
        .expect("spec/build.json is invalid JSON")
});

fn default_now() -> jiff::Zoned {
    SPEC["now"]
        .as_str()
        .expect("top-level 'now' missing")
        .parse()
        .expect("invalid 'now' timestamp")
}

fn parse_zoned(s: &str) -> jiff::Zoned {
    s.parse()
        .unwrap_or_else(|e| panic!("bad timestamp '{s}': {e}"))
}

/// Fails on a field this runner does not check, and on a case with none of the
/// section's assertion fields (spec/README.md, "Writing a runner").
fn check_fields(case: &Value, inputs: &[&str], assertions: &[&str]) {
    let name = case["name"].as_str().unwrap_or("<unnamed>");
    let fields = case.as_object().expect("a case should be an object");
    for key in fields.keys().map(String::as_str) {
        assert!(
            ["name", "description"].contains(&key)
                || inputs.contains(&key)
                || assertions.contains(&key),
            "case '{name}': field '{key}' is not known to this runner"
        );
    }
    assert!(
        assertions.is_empty() || assertions.iter().any(|a| fields.contains_key(*a)),
        "case '{name}' has none of the assertion fields {assertions:?}"
    );
}

fn run_parse_roundtrip(section: &str, index: usize) {
    let case = &SPEC["parse"][section]["tests"][index];
    check_fields(case, &["input"], &["canonical"]);
    let input = case["input"].as_str().unwrap();
    let canonical = case["canonical"].as_str().unwrap();

    let schedule =
        Schedule::parse(input).unwrap_or_else(|e| panic!("parse failed for '{input}': {e}"));
    let display = schedule.to_string();
    assert_eq!(display, canonical, "display mismatch for '{input}'");

    let s2 = Schedule::parse(canonical)
        .unwrap_or_else(|e| panic!("re-parse canonical failed for '{canonical}': {e}"));
    assert_eq!(
        s2.to_string(),
        canonical,
        "canonical not idempotent for '{canonical}'"
    );
    assert_rebuilds(&schedule);
    assert_equals_parse_of_display(&schedule);
}

/// spec/README.md, "Equality".
fn assert_equals_parse_of_display(schedule: &Schedule) {
    let reparsed = Schedule::parse(&schedule.to_string()).unwrap();
    assert_eq!(&reparsed, schedule, "parse of '{schedule}'");
    assert_eq!(
        hash_of(&reparsed),
        hash_of(schedule),
        "hash of '{schedule}'"
    );
}

fn hash_of(schedule: &Schedule) -> u64 {
    let mut hasher = DefaultHasher::new();
    schedule.hash(&mut hasher);
    hasher.finish()
}

fn assert_rebuilds(schedule: &Schedule) {
    let rebuilt = Schedule::from_parts(schedule.to_parts())
        .unwrap_or_else(|e| panic!("from_parts of '{schedule}' failed: {e}"));
    assert_eq!(&rebuilt, schedule, "from_parts of '{schedule}'");
    assert_eq!(rebuilt.to_string(), schedule.to_string());
}

fn run_build(group: &str, index: usize) {
    let case = &BUILD[group]["tests"][index];
    check_fields(case, &["parts"], &["error", "canonical"]);
    let name = case["name"].as_str().unwrap();
    let result = Schedule::from_parts(build_parts(&case["parts"]));
    if let Some(expected) = case.get("error") {
        let fields = expected.as_object().expect("'error' should be an object");
        for key in fields.keys() {
            assert!(
                ["kind", "message"].contains(&key.as_str()),
                "error field '{key}' is not known to this runner"
            );
        }
        assert_eq!(
            expected["kind"], "eval",
            "case '{name}' expects another kind"
        );
        let message = expected["message"].as_str().unwrap();
        match result {
            Err(error @ ScheduleError::Eval { .. }) => {
                assert_eq!(error.to_string(), message, "message for '{name}'");
                assert_eq!(error.display_rich(), format!("error: {message}"));
            }
            other => panic!("case '{name}': expected an eval error, got {other:?}"),
        }
    } else {
        let canonical = case["canonical"].as_str().unwrap();
        let schedule = result.unwrap_or_else(|e| panic!("case '{name}' failed to build: {e}"));
        assert_eq!(schedule.to_string(), canonical, "toString for '{name}'");
        let parsed = Schedule::parse(canonical)
            .unwrap_or_else(|e| panic!("case '{name}': '{canonical}' does not parse: {e}"));
        assert_eq!(parsed, schedule, "case '{name}': parse(toString) differs");
    }
}

fn build_parts(parts: &Value) -> ScheduleParts {
    let fields = parts.as_object().expect("'parts' should be an object");
    for key in fields.keys() {
        assert!(
            [
                "expression",
                "timezone",
                "except",
                "until",
                "starting",
                "during"
            ]
            .contains(&key.as_str()),
            "parts field '{key}' is not known to this runner"
        );
    }
    let starting: Option<String> = read_field(fields, "starting", Value::Null);
    ScheduleParts {
        expression: read_field(fields, "expression", Value::Null),
        timezone: read_field(fields, "timezone", Value::Null),
        except: read_field(fields, "except", Value::Array(vec![])),
        until: read_field(fields, "until", Value::Null),
        starting: starting.map(|date| date.parse().expect("starting should be a date jiff reads")),
        during: read_field(fields, "during", Value::Array(vec![])),
    }
}

fn read_field<T: serde::de::DeserializeOwned>(
    fields: &serde_json::Map<String, Value>,
    key: &str,
    absent: Value,
) -> T {
    serde_json::from_value(fields.get(key).cloned().unwrap_or(absent))
        .unwrap_or_else(|e| panic!("parts field '{key}' cannot be read: {e}"))
}

fn run_parse_error(index: usize) {
    let case = &SPEC["parse_errors"]["tests"][index];
    check_fields(case, &["input"], &["error", "display"]);
    let input = case["input"].as_str().unwrap();
    let expected = case["error"]
        .as_object()
        .expect("'error' should be an object");
    for key in expected.keys() {
        assert!(
            ["kind", "message", "span", "suggestion"].contains(&key.as_str()),
            "error field '{key}' is not known to this runner"
        );
    }

    assert!(
        !Schedule::validate(input),
        "validate('{input}') is true, expected false"
    );
    let error = match Schedule::parse(input) {
        Ok(s) => panic!("expected parse error for '{input}', got: {s}"),
        Err(e) => e,
    };
    let (kind, span, suggestion) = match &error {
        ScheduleError::Lex { span, .. } => ("lex", span, None),
        ScheduleError::Parse {
            span, suggestion, ..
        } => ("parse", span, suggestion.as_deref()),
        other => panic!("'{input}' failed with neither a lex nor a parse error: {other:?}"),
    };
    assert_eq!(kind, expected["kind"], "kind for '{input}'");
    assert_eq!(
        error.to_string(),
        expected["message"],
        "message for '{input}'"
    );
    assert_eq!(
        serde_json::json!([span.start, span.end]),
        expected["span"],
        "span for '{input}'"
    );
    assert_eq!(
        suggestion,
        expected.get("suggestion").map(|s| s.as_str().unwrap()),
        "suggestion for '{input}'"
    );
    if let Some(display) = case.get("display") {
        assert_eq!(
            error.display_rich(),
            display.as_str().unwrap(),
            "displayRich for '{input}'"
        );
    }
}

fn run_eval(section: &str, index: usize) {
    let case = &SPEC["eval"][section]["tests"][index];
    check_fields(
        case,
        &["expression", "now", "next_n_count"],
        &["next", "next_date", "next_n", "next_n_length"],
    );
    let expr_str = case["expression"].as_str().unwrap();

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));

    let now = case["now"]
        .as_str()
        .map(parse_zoned)
        .unwrap_or_else(default_now);

    if let Some(expected_val) = case.get("next") {
        let result = schedule.next_from(&now);
        if expected_val.is_null() {
            assert!(
                result.is_none(),
                "expected null for '{expr_str}', got {:?}",
                result.map(|z| z.to_string())
            );
        } else {
            let expected = expected_val.as_str().unwrap();
            let got = result.unwrap_or_else(|| panic!("next: got None, expected '{expected}'"));
            assert_eq!(got.to_string(), expected, "next mismatch for '{expr_str}'");
        }
    }

    if let Some(expected_date) = case.get("next_date") {
        let expected = expected_date.as_str().unwrap();
        let got = schedule
            .next_from(&now)
            .unwrap_or_else(|| panic!("next_date: got None, expected '{expected}'"));
        assert_eq!(
            got.date().to_string(),
            expected,
            "next_date mismatch for '{expr_str}'"
        );
    }

    if let Some(expected_arr) = case.get("next_n") {
        let expected: Vec<&str> = expected_arr
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert!(
            !expected.is_empty() || case.get("next_n_count").is_some(),
            "an empty next_n asserts nothing without next_n_count for '{expr_str}'"
        );

        let n_count = next_n_count(case).unwrap_or(expected.len());

        let results = schedule.next_n_from(&now, n_count);
        let got: Vec<String> = results.iter().map(|z| z.to_string()).collect();

        assert_eq!(
            got.len(),
            expected.len(),
            "next_n length mismatch for '{expr_str}': got {got:?}"
        );
        for (j, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
            assert_eq!(g, e, "next_n[{j}] mismatch for '{expr_str}'");
        }
    }

    if let Some(expected_len) = case.get("next_n_length") {
        let expected = expected_len.as_u64().unwrap() as usize;
        let n_count = next_n_count(case)
            .unwrap_or_else(|| panic!("next_n_length needs next_n_count for '{expr_str}'"));
        let results = schedule.next_n_from(&now, n_count);
        assert_eq!(
            results.len(),
            expected,
            "next_n_length mismatch for '{expr_str}'"
        );
    }
}

/// `next_n_from` takes a `usize`, so a negative count is checked as 0
/// (spec/README.md, "Writing a runner").
fn next_n_count(case: &Value) -> Option<usize> {
    let count = case.get("next_n_count")?;
    let count = count.as_i64().expect("next_n_count should be an integer");
    Some(usize::try_from(count).unwrap_or(0))
}

#[test]
fn a_negative_next_n_count_is_checked_as_zero() {
    let case =
        serde_json::json!({ "next_n_count": -1, "next_n": ["2026-02-07T09:00:00+00:00[UTC]"] });
    assert_eq!(next_n_count(&case), Some(0));
}

fn run_eval_matches(section: &str, index: usize) {
    let case = &SPEC["eval"][section]["tests"][index];
    check_fields(case, &["expression", "datetime"], &["expected"]);
    let expr_str = case["expression"].as_str().unwrap();
    let dt_str = case["datetime"].as_str().unwrap();
    let expected = case["expected"].as_bool().unwrap();

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));
    let dt = parse_zoned(dt_str);
    let got = schedule.matches(&dt);

    assert_eq!(
        got, expected,
        "matches mismatch for '{expr_str}' at {dt_str}"
    );
}

fn run_eval_occurrences(section: &str, index: usize) {
    let case = &SPEC["eval"][section]["tests"][index];
    check_fields(case, &["expression", "from", "take"], &["expected"]);
    let expr_str = case["expression"].as_str().unwrap();
    let from_str = case["from"].as_str().unwrap();
    let take = case["take"].as_u64().unwrap() as usize;
    let expected: Vec<&str> = case["expected"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));
    let from = parse_zoned(from_str);

    let results: Vec<jiff::Zoned> = schedule.occurrences(&from).take(take).collect();

    let got: Vec<String> = results.iter().map(|z| z.to_string()).collect();

    assert_eq!(
        got.len(),
        expected.len(),
        "occurrences length mismatch for '{expr_str}': got {got:?}"
    );
    for (j, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
        assert_eq!(g, e, "occurrences[{j}] mismatch for '{expr_str}'");
    }
}

fn run_eval_between(section: &str, index: usize) {
    let case = &SPEC["eval"][section]["tests"][index];
    check_fields(
        case,
        &["expression", "from", "to"],
        &["expected", "expected_count"],
    );
    let expr_str = case["expression"].as_str().unwrap();
    let from_str = case["from"].as_str().unwrap();
    let to_str = case["to"].as_str().unwrap();

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));
    let from = parse_zoned(from_str);
    let to = parse_zoned(to_str);

    let results: Vec<jiff::Zoned> = schedule.between(&from, &to).collect();

    if let Some(expected_arr) = case.get("expected") {
        let expected: Vec<&str> = expected_arr
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();

        let got: Vec<String> = results.iter().map(|z| z.to_string()).collect();

        assert_eq!(
            got.len(),
            expected.len(),
            "between length mismatch for '{expr_str}': got {got:?}"
        );
        for (j, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
            assert_eq!(g, e, "between[{j}] mismatch for '{expr_str}'");
        }
    } else if let Some(expected_count) = case.get("expected_count") {
        let count = expected_count.as_u64().unwrap() as usize;
        assert_eq!(
            results.len(),
            count,
            "between count mismatch for '{expr_str}'"
        );
    }
}

fn run_eval_previous_from(section: &str, index: usize) {
    let case = &SPEC["eval"][section]["tests"][index];
    check_fields(case, &["expression", "now"], &["expected"]);
    let expr_str = case["expression"].as_str().unwrap();
    let now_str = case["now"].as_str().unwrap();

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));
    let now = parse_zoned(now_str);

    let result = schedule.previous_from(&now);

    if case["expected"].is_null() {
        assert!(
            result.is_none(),
            "expected None for '{expr_str}', got {:?}",
            result
        );
    } else {
        let expected = case["expected"].as_str().unwrap();
        let got = result
            .as_ref()
            .map(|z| z.to_string())
            .unwrap_or_else(|| "None".to_string());
        assert_eq!(got, expected, "previous_from mismatch for '{expr_str}'");
    }
}

fn run_cron_to_cron(section: &str, index: usize) {
    let case = &SPEC["cron"][section]["tests"][index];
    check_fields(case, &["hron"], &["cron"]);
    let hron_expr = case["hron"].as_str().unwrap();
    let expected_cron = case["cron"].as_str().unwrap();

    let schedule = Schedule::parse(hron_expr)
        .unwrap_or_else(|e| panic!("parse failed for '{hron_expr}': {e}"));
    let got = schedule
        .to_cron()
        .unwrap_or_else(|e| panic!("to_cron failed for '{hron_expr}': {e}"));
    assert_eq!(got, expected_cron, "to_cron mismatch for '{hron_expr}'");
}

fn run_cron_to_cron_error(section: &str, index: usize) {
    let case = &SPEC["cron"][section]["tests"][index];
    check_fields(case, &["hron"], &["error"]);
    let hron_expr = case["hron"].as_str().unwrap();

    let schedule = Schedule::parse(hron_expr)
        .unwrap_or_else(|e| panic!("parse failed for '{hron_expr}': {e}"));
    assert_cron_error(schedule.to_cron(), case, hron_expr);
}

fn assert_cron_error<T: std::fmt::Debug>(
    result: Result<T, hron::ScheduleError>,
    case: &Value,
    input: &str,
) {
    let expected = case["error"].as_str().unwrap();
    match result {
        Ok(got) => panic!("expected cron error for '{input}', got {got:?}"),
        Err(hron::ScheduleError::Cron { message }) => {
            assert_eq!(message, expected, "cron error message for '{input}'")
        }
        Err(e) => panic!("expected a cron error for '{input}', got {e:?}"),
    }
}

fn run_cron_from_cron(section: &str, index: usize) {
    let case = &SPEC["cron"][section]["tests"][index];
    check_fields(case, &["cron"], &["hron"]);
    let cron_expr = case["cron"].as_str().unwrap();
    let expected_hron = case["hron"].as_str().unwrap();

    let schedule = Schedule::from_cron(cron_expr)
        .unwrap_or_else(|e| panic!("from_cron failed for '{cron_expr}': {e}"));
    let got = schedule.to_string();
    assert_eq!(got, expected_hron, "from_cron mismatch for '{cron_expr}'");
    assert_rebuilds(&schedule);
    assert_equals_parse_of_display(&schedule);
}

fn run_cron_from_cron_error(section: &str, index: usize) {
    let case = &SPEC["cron"][section]["tests"][index];
    check_fields(case, &["cron"], &["error"]);
    let cron_expr = case["cron"].as_str().unwrap();
    assert_cron_error(
        Schedule::from_cron(cron_expr).map(|s| s.to_string()),
        case,
        cron_expr,
    );
}

fn run_cron_roundtrip(section: &str, index: usize) {
    let case = &SPEC["cron"][section]["tests"][index];
    check_fields(case, &["hron"], &[]);
    let hron_expr = case["hron"].as_str().unwrap();

    let schedule = Schedule::parse(hron_expr)
        .unwrap_or_else(|e| panic!("parse failed for '{hron_expr}': {e}"));
    let cron1 = schedule
        .to_cron()
        .unwrap_or_else(|e| panic!("to_cron failed for '{hron_expr}': {e}"));
    let back = Schedule::from_cron(&cron1)
        .unwrap_or_else(|e| panic!("from_cron failed for '{cron1}': {e}"));
    let cron2 = back
        .to_cron()
        .unwrap_or_else(|e| panic!("re-to_cron failed for '{hron_expr}': {e}"));
    assert_eq!(cron1, cron2, "roundtrip mismatch for '{hron_expr}'");
}

/// Checks every rule listed in `invariants.rules` (spec/README.md, "Invariants")
/// and reports all that fail, including rules this runner does not implement.
fn run_invariants(index: usize) {
    let case = &SPEC["invariants"]["tests"][index];
    check_fields(case, &["expression", "now"], &[]);
    let name = case["name"].as_str().unwrap();
    let expr_str = case["expression"].as_str().unwrap();
    let count = SPEC["invariants"]["count"].as_u64().unwrap() as usize;
    let rules = SPEC["invariants"]["rules"]
        .as_object()
        .expect("invariants.rules should be an object");

    let schedule =
        Schedule::parse(expr_str).unwrap_or_else(|e| panic!("parse failed for '{expr_str}': {e}"));
    let now = parse_zoned(case["now"].as_str().unwrap());
    let next_n = schedule.next_n_from(&now, count);

    let failures: Vec<String> = rules
        .keys()
        .filter_map(|rule| {
            let result = match rule.as_str() {
                "next_matches" => next_matches(&schedule, &now),
                "next_after_now" => next_after_now(&schedule, &now),
                "next_n_chain" => next_n_chain(&schedule, &now, &next_n),
                "occurrences_prefix" => occurrences_prefix(&schedule, &now, count, &next_n),
                "between_window" => between_window(&schedule, &now, &next_n),
                "prev_inverse" => prev_inverse(&schedule, &next_n),
                "prev_before_now" => prev_before_now(&schedule, &now),
                "display_roundtrip" => display_roundtrip(&schedule),
                _ => Err("rule is not implemented by this runner".into()),
            };
            result.err().map(|msg| format!("  {rule}: {msg}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "invariant '{name}' ('{expr_str}' at {now}) failed:\n{}",
        failures.join("\n")
    );
}

type InvariantResult = Result<(), String>;

fn same_instants(a: &[jiff::Zoned], b: &[jiff::Zoned]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.timestamp() == y.timestamp())
}

fn show(list: &[jiff::Zoned]) -> Vec<String> {
    list.iter().map(|z| z.to_string()).collect()
}

fn next_matches(schedule: &Schedule, now: &jiff::Zoned) -> InvariantResult {
    match schedule.next_from(now) {
        Some(t) if !schedule.matches(&t) => Err(format!("matches({t}) is false")),
        _ => Ok(()),
    }
}

fn next_after_now(schedule: &Schedule, now: &jiff::Zoned) -> InvariantResult {
    match schedule.next_from(now) {
        Some(t) if t.timestamp() <= now.timestamp() => {
            Err(format!("nextFrom(now) is {t}, not after now"))
        }
        _ => Ok(()),
    }
}

fn next_n_chain(schedule: &Schedule, now: &jiff::Zoned, next_n: &[jiff::Zoned]) -> InvariantResult {
    if next_n
        .windows(2)
        .any(|w| w[0].timestamp() >= w[1].timestamp())
    {
        return Err(format!("not strictly increasing: {:?}", show(next_n)));
    }
    if next_n.is_empty() && schedule.next_from(now).is_some() {
        return Err("next_n is empty but nextFrom(now) is not null".into());
    }
    let mut cursor = now;
    for (i, got) in next_n.iter().enumerate() {
        let expected = schedule.next_from(cursor);
        if expected.as_ref().map(|t| t.timestamp()) != Some(got.timestamp()) {
            return Err(format!(
                "next_n[{i}] is {got}, but nextFrom({cursor}) is {expected:?}"
            ));
        }
        cursor = got;
    }
    Ok(())
}

fn occurrences_prefix(
    schedule: &Schedule,
    now: &jiff::Zoned,
    count: usize,
    next_n: &[jiff::Zoned],
) -> InvariantResult {
    let taken: Vec<jiff::Zoned> = schedule.occurrences(now).take(count).collect();
    if same_instants(&taken, next_n) {
        Ok(())
    } else {
        Err(format!(
            "occurrences {:?} vs next_n {:?}",
            show(&taken),
            show(next_n)
        ))
    }
}

fn between_window(
    schedule: &Schedule,
    now: &jiff::Zoned,
    next_n: &[jiff::Zoned],
) -> InvariantResult {
    let Some(last) = next_n.last() else {
        return Ok(());
    };
    let got: Vec<jiff::Zoned> = schedule.between(now, last).collect();
    if same_instants(&got, next_n) {
        Ok(())
    } else {
        Err(format!(
            "between {:?} vs next_n {:?}",
            show(&got),
            show(next_n)
        ))
    }
}

fn prev_inverse(schedule: &Schedule, next_n: &[jiff::Zoned]) -> InvariantResult {
    for w in next_n.windows(2) {
        let got = schedule.previous_from(&w[1]);
        if got.as_ref().map(|p| p.timestamp()) != Some(w[0].timestamp()) {
            return Err(format!(
                "previousFrom({}) is {got:?}, expected {}",
                w[1], w[0]
            ));
        }
    }
    Ok(())
}

fn prev_before_now(schedule: &Schedule, now: &jiff::Zoned) -> InvariantResult {
    let Some(p) = schedule.previous_from(now) else {
        return Ok(());
    };
    if p.timestamp() >= now.timestamp() {
        return Err(format!("previousFrom(now) is {p}, not before now"));
    }
    if !schedule.matches(&p) {
        return Err(format!("matches({p}) is false"));
    }
    match schedule.next_from(&p) {
        Some(n) if n.timestamp() < now.timestamp() => Err(format!(
            "nextFrom({p}) is {n}, an occurrence between previousFrom(now) and now"
        )),
        _ => Ok(()),
    }
}

fn display_roundtrip(schedule: &Schedule) -> InvariantResult {
    let display = schedule.to_string();
    let again = Schedule::parse(&display)
        .map_err(|e| format!("re-parse of '{display}' failed: {e}"))?
        .to_string();
    if again == display {
        Ok(())
    } else {
        Err(format!("'{display}' re-displays as '{again}'"))
    }
}

// One test function per spec case, generated by build.rs.

include!(concat!(env!("OUT_DIR"), "/conformance_tests.rs"));
