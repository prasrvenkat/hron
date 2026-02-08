/// Build script: generates individual `#[test]` functions from spec/tests.json
/// so each conformance case appears separately in `cargo test` output.
use std::env;
use std::fs;
use std::io::Write;
use std::path::Path;

fn main() {
    let spec_path = Path::new("../../spec/tests.json");
    println!("cargo:rerun-if-changed={}", spec_path.display());

    let spec_str = fs::read_to_string(spec_path).expect("failed to read spec/tests.json");
    let spec: serde_json::Value = serde_json::from_str(&spec_str).expect("invalid JSON in spec");

    let out_dir = env::var("OUT_DIR").unwrap();
    let dest = Path::new(&out_dir).join("conformance_tests.rs");
    let mut f = fs::File::create(&dest).unwrap();

    // --- Parse roundtrip ---
    let parse = &spec["parse"];
    for section in [
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
    ] {
        for (i, case) in iter_tests(&parse[section]).enumerate() {
            let name = test_name(case, i);
            emit(
                &mut f,
                &format!("parse_{section}_{name}"),
                "run_parse_roundtrip",
                section,
                i,
            );
        }
    }

    // --- Parse errors ---
    for (i, case) in iter_tests(&spec["parse_errors"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(&mut f, &format!("parse_error_{name}"), "run_parse_error", i);
    }

    // --- Eval ---
    let eval = &spec["eval"];
    for section in [
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
    ] {
        for (i, case) in iter_tests(&eval[section]).enumerate() {
            let name = test_name(case, i);
            emit(
                &mut f,
                &format!("eval_{section}_{name}"),
                "run_eval",
                section,
                i,
            );
        }
    }

    // --- Eval matches ---
    for (i, case) in iter_tests(&eval["matches"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("eval_matches_{name}"),
            "run_eval_matches",
            i,
        );
    }

    // --- Cron ---
    let cron = &spec["cron"];
    for (i, case) in iter_tests(&cron["to_cron"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("cron_to_cron_{name}"),
            "run_cron_to_cron",
            i,
        );
    }
    for (i, case) in iter_tests(&cron["to_cron_errors"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("cron_to_cron_error_{name}"),
            "run_cron_to_cron_error",
            i,
        );
    }
    for (i, case) in iter_tests(&cron["from_cron"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("cron_from_cron_{name}"),
            "run_cron_from_cron",
            i,
        );
    }
    for (i, case) in iter_tests(&cron["from_cron_errors"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("cron_from_cron_error_{name}"),
            "run_cron_from_cron_error",
            i,
        );
    }
    for (i, case) in iter_tests(&cron["roundtrip"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(
            &mut f,
            &format!("cron_roundtrip_{name}"),
            "run_cron_roundtrip",
            i,
        );
    }
}

fn iter_tests(section: &serde_json::Value) -> impl Iterator<Item = &serde_json::Value> {
    section["tests"]
        .as_array()
        .expect("section missing 'tests' array")
        .iter()
}

fn test_name(case: &serde_json::Value, index: usize) -> String {
    let raw = case["name"]
        .as_str()
        .map(String::from)
        .unwrap_or_else(|| format!("case_{index}"));
    sanitize(&raw)
}

fn sanitize(name: &str) -> String {
    let s: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    // collapse consecutive underscores, trim trailing
    let mut result = String::new();
    let mut prev_underscore = false;
    for c in s.chars() {
        if c == '_' {
            if !prev_underscore {
                result.push('_');
            }
            prev_underscore = true;
        } else {
            result.push(c);
            prev_underscore = false;
        }
    }
    result.trim_end_matches('_').to_string()
}

fn emit(f: &mut fs::File, fn_name: &str, runner: &str, section: &str, index: usize) {
    writeln!(f, "#[test]").unwrap();
    writeln!(f, "fn {fn_name}() {{ {runner}(\"{section}\", {index}); }}").unwrap();
}

fn emit_flat(f: &mut fs::File, fn_name: &str, runner: &str, index: usize) {
    writeln!(f, "#[test]").unwrap();
    writeln!(f, "fn {fn_name}() {{ {runner}({index}); }}").unwrap();
}
