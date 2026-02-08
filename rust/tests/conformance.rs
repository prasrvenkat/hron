//! Conformance test runner — drives all tests from spec/tests.json.
//!
//! This makes the spec the single source of truth. Language-specific tests
//! (CLI, internal unit tests) remain separate.

use hron::Schedule;
use serde_json::Value;

static SPEC: &str = include_str!("../../spec/tests.json");

fn spec() -> Value {
    serde_json::from_str(SPEC).expect("spec/tests.json is invalid JSON")
}

fn default_now(root: &Value) -> jiff::Zoned {
    parse_zoned(root["now"].as_str().expect("top-level 'now' missing"))
}

fn parse_zoned(s: &str) -> jiff::Zoned {
    s.parse::<jiff::Zoned>()
        .unwrap_or_else(|e| panic!("bad timestamp '{s}': {e}"))
}

fn tests_array(section: &Value) -> &[Value] {
    section["tests"]
        .as_array()
        .expect("section missing 'tests' array")
        .as_slice()
}

fn test_name(case: &Value, section_path: &str, index: usize) -> String {
    match case["name"].as_str() {
        Some(n) => format!("{section_path}.{n}"),
        None => format!("{section_path}[{index}]"),
    }
}

// ---------------------------------------------------------------------------
// FailCollector: run all cases, report all failures at the end
// ---------------------------------------------------------------------------

struct FailCollector {
    failures: Vec<String>,
    pass: usize,
}

impl FailCollector {
    fn new() -> Self {
        Self {
            failures: Vec::new(),
            pass: 0,
        }
    }

    fn fail(&mut self, name: &str, msg: String) {
        self.failures.push(format!("  FAIL {name}: {msg}"));
    }

    fn pass(&mut self) {
        self.pass += 1;
    }

    fn finish(self, label: &str) {
        if self.failures.is_empty() {
            eprintln!("{label}: {}/{} passed", self.pass, self.pass);
        } else {
            let total = self.pass + self.failures.len();
            let msg = format!(
                "{label}: {}/{total} passed, {} failed:\n{}",
                self.pass,
                self.failures.len(),
                self.failures.join("\n")
            );
            panic!("{msg}");
        }
    }
}

// ===========================================================================
// Parse conformance
// ===========================================================================

#[test]
fn conformance_parse_roundtrip() {
    let root = spec();
    let parse = &root["parse"];
    let mut fc = FailCollector::new();

    let sections = [
        "day_repeat",
        "interval_repeat",
        "week_repeat",
        "month_repeat",
        "ordinal_repeat",
        "single_date",
        "year_repeat",
        "except_clause",
        "until_clause",
        "starting_clause",
        "during_clause",
        "timezone_clause",
        "combined_clauses",
        "case_insensitivity",
    ];

    for section_name in sections {
        let section = &parse[section_name];
        for (i, case) in tests_array(section).iter().enumerate() {
            let name = test_name(case, &format!("parse.{section_name}"), i);
            let input = case["input"].as_str().unwrap();
            let canonical = case["canonical"].as_str().unwrap();

            // parse(input).to_string() == canonical
            match Schedule::parse(input) {
                Ok(schedule) => {
                    let display = schedule.to_string();
                    if display != canonical {
                        fc.fail(&name, format!("got '{display}', expected '{canonical}'"));
                        continue;
                    }
                    // parse(canonical).to_string() == canonical (idempotent)
                    match Schedule::parse(canonical) {
                        Ok(s2) => {
                            let d2 = s2.to_string();
                            if d2 != canonical {
                                fc.fail(
                                    &name,
                                    format!("canonical not idempotent: '{d2}' != '{canonical}'"),
                                );
                                continue;
                            }
                        }
                        Err(e) => {
                            fc.fail(&name, format!("re-parse canonical failed: {e}"));
                            continue;
                        }
                    }
                    fc.pass();
                }
                Err(e) => {
                    fc.fail(&name, format!("parse failed: {e}"));
                }
            }
        }
    }

    fc.finish("parse_roundtrip");
}

#[test]
fn conformance_parse_errors() {
    let root = spec();
    let section = &root["parse_errors"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "parse_errors", i);
        let input = case["input"].as_str().unwrap();

        match Schedule::parse(input) {
            Ok(s) => fc.fail(&name, format!("should fail, got: {s}")),
            Err(_) => fc.pass(),
        }
    }

    fc.finish("parse_errors");
}

// ===========================================================================
// Eval conformance
// ===========================================================================

#[test]
fn conformance_eval() {
    let root = spec();
    let eval = &root["eval"];
    let default = default_now(&root);
    let mut fc = FailCollector::new();

    let sections = [
        "day_repeat",
        "interval_repeat",
        "month_repeat",
        "ordinal_repeat",
        "week_repeat",
        "single_date",
        "year_repeat",
        "except",
        "until",
        "except_and_until",
        "n_occurrences",
        "multi_time",
        "during",
        "day_ranges",
        "leap_year",
        "dst_spring_forward",
        "dst_fall_back",
    ];

    for section_name in sections {
        let section = &eval[section_name];
        for (i, case) in tests_array(section).iter().enumerate() {
            let name = test_name(case, &format!("eval.{section_name}"), i);
            let expr_str = case["expression"].as_str().unwrap();

            let schedule = match Schedule::parse(expr_str) {
                Ok(s) => s,
                Err(e) => {
                    fc.fail(&name, format!("parse failed: {e}"));
                    continue;
                }
            };

            let now = case["now"]
                .as_str()
                .map(|s| parse_zoned(s))
                .unwrap_or_else(|| default.clone());

            // ---- next (full timestamp) ----
            if let Some(expected_val) = case.get("next") {
                let result = schedule.next_from(&now);
                if expected_val.is_null() {
                    if let Some(got) = result {
                        fc.fail(&name, format!("expected null, got {got}"));
                        continue;
                    }
                } else {
                    let expected = expected_val.as_str().unwrap();
                    match result {
                        Some(got) => {
                            if got.to_string() != expected {
                                fc.fail(&name, format!("next: got '{got}', expected '{expected}'"));
                                continue;
                            }
                        }
                        None => {
                            fc.fail(&name, format!("next: got None, expected '{expected}'"));
                            continue;
                        }
                    }
                }
            }

            // ---- next_date (date-only check) ----
            if let Some(expected_date) = case.get("next_date") {
                let expected = expected_date.as_str().unwrap();
                match schedule.next_from(&now) {
                    Some(got) => {
                        let got_date = got.date().to_string();
                        if got_date != expected {
                            fc.fail(
                                &name,
                                format!("next_date: got '{got_date}', expected '{expected}'"),
                            );
                            continue;
                        }
                    }
                    None => {
                        fc.fail(&name, format!("next_date: got None, expected '{expected}'"));
                        continue;
                    }
                }
            }

            // ---- next_n (list of timestamps) ----
            if let Some(expected_arr) = case.get("next_n") {
                let expected: Vec<&str> = expected_arr
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|v| v.as_str().unwrap())
                    .collect();

                let n_count = case
                    .get("next_n_count")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(expected.len() as u64) as usize;

                let results = schedule.next_n_from(&now, n_count);
                let got: Vec<String> = results.iter().map(|z| z.to_string()).collect();

                if got.len() != expected.len() {
                    fc.fail(
                        &name,
                        format!(
                            "next_n length: got {}, expected {} (got: {:?})",
                            got.len(),
                            expected.len(),
                            got
                        ),
                    );
                    continue;
                }

                let mut mismatch = false;
                for (j, (g, e)) in got.iter().zip(expected.iter()).enumerate() {
                    if g != e {
                        fc.fail(&name, format!("next_n[{j}]: got '{g}', expected '{e}'"));
                        mismatch = true;
                        break;
                    }
                }
                if mismatch {
                    continue;
                }
            }

            // ---- next_n_length (just check count) ----
            if let Some(expected_len) = case.get("next_n_length") {
                let expected = expected_len.as_u64().unwrap() as usize;
                let n_count = case["next_n_count"].as_u64().unwrap() as usize;
                let results = schedule.next_n_from(&now, n_count);
                if results.len() != expected {
                    fc.fail(
                        &name,
                        format!(
                            "next_n_length: got {}, expected {}",
                            results.len(),
                            expected
                        ),
                    );
                    continue;
                }
            }

            fc.pass();
        }
    }

    fc.finish("eval");
}

#[test]
fn conformance_eval_matches() {
    let root = spec();
    let section = &root["eval"]["matches"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "eval.matches", i);
        let expr_str = case["expression"].as_str().unwrap();
        let dt_str = case["datetime"].as_str().unwrap();
        let expected = case["expected"].as_bool().unwrap();

        let schedule = match Schedule::parse(expr_str) {
            Ok(s) => s,
            Err(e) => {
                fc.fail(&name, format!("parse failed: {e}"));
                continue;
            }
        };

        let dt = parse_zoned(dt_str);
        let got = schedule.matches(&dt);

        if got != expected {
            fc.fail(&name, format!("got {got}, expected {expected}"));
        } else {
            fc.pass();
        }
    }

    fc.finish("eval_matches");
}

// ===========================================================================
// Cron conformance
// ===========================================================================

#[test]
fn conformance_cron_to_cron() {
    let root = spec();
    let section = &root["cron"]["to_cron"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "cron.to_cron", i);
        let hron_expr = case["hron"].as_str().unwrap();
        let expected_cron = case["cron"].as_str().unwrap();

        let schedule = match Schedule::parse(hron_expr) {
            Ok(s) => s,
            Err(e) => {
                fc.fail(&name, format!("parse failed: {e}"));
                continue;
            }
        };

        match schedule.to_cron() {
            Ok(got) => {
                if got != expected_cron {
                    fc.fail(&name, format!("got '{got}', expected '{expected_cron}'"));
                } else {
                    fc.pass();
                }
            }
            Err(e) => {
                fc.fail(&name, format!("to_cron failed: {e}"));
            }
        }
    }

    fc.finish("cron_to_cron");
}

#[test]
fn conformance_cron_to_cron_errors() {
    let root = spec();
    let section = &root["cron"]["to_cron_errors"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "cron.to_cron_errors", i);
        let hron_expr = case["hron"].as_str().unwrap();

        let schedule = match Schedule::parse(hron_expr) {
            Ok(s) => s,
            Err(e) => {
                fc.fail(&name, format!("parse failed: {e}"));
                continue;
            }
        };

        match schedule.to_cron() {
            Ok(got) => {
                fc.fail(&name, format!("should fail, got '{got}'"));
            }
            Err(_) => fc.pass(),
        }
    }

    fc.finish("cron_to_cron_errors");
}

#[test]
fn conformance_cron_from_cron() {
    let root = spec();
    let section = &root["cron"]["from_cron"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "cron.from_cron", i);
        let cron_expr = case["cron"].as_str().unwrap();
        let expected_hron = case["hron"].as_str().unwrap();

        match Schedule::from_cron(cron_expr) {
            Ok(schedule) => {
                let got = schedule.to_string();
                if got != expected_hron {
                    fc.fail(&name, format!("got '{got}', expected '{expected_hron}'"));
                } else {
                    fc.pass();
                }
            }
            Err(e) => {
                fc.fail(&name, format!("from_cron failed: {e}"));
            }
        }
    }

    fc.finish("cron_from_cron");
}

#[test]
fn conformance_cron_from_cron_errors() {
    let root = spec();
    let section = &root["cron"]["from_cron_errors"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "cron.from_cron_errors", i);
        let cron_expr = case["cron"].as_str().unwrap();

        match Schedule::from_cron(cron_expr) {
            Ok(s) => fc.fail(&name, format!("should fail, got: {s}")),
            Err(_) => fc.pass(),
        }
    }

    fc.finish("cron_from_cron_errors");
}

#[test]
fn conformance_cron_roundtrip() {
    let root = spec();
    let section = &root["cron"]["roundtrip"];
    let mut fc = FailCollector::new();

    for (i, case) in tests_array(section).iter().enumerate() {
        let name = test_name(case, "cron.roundtrip", i);
        let hron_expr = case["hron"].as_str().unwrap();

        let schedule = match Schedule::parse(hron_expr) {
            Ok(s) => s,
            Err(e) => {
                fc.fail(&name, format!("parse failed: {e}"));
                continue;
            }
        };

        let cron1 = match schedule.to_cron() {
            Ok(c) => c,
            Err(e) => {
                fc.fail(&name, format!("to_cron failed: {e}"));
                continue;
            }
        };

        let back = match Schedule::from_cron(&cron1) {
            Ok(s) => s,
            Err(e) => {
                fc.fail(&name, format!("from_cron failed: {e}"));
                continue;
            }
        };

        match back.to_cron() {
            Ok(cron2) => {
                if cron1 != cron2 {
                    fc.fail(&name, format!("roundtrip mismatch: '{cron1}' != '{cron2}'"));
                } else {
                    fc.pass();
                }
            }
            Err(e) => {
                fc.fail(&name, format!("re-to_cron failed: {e}"));
            }
        }
    }

    fc.finish("cron_roundtrip");
}
