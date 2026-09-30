//! Generates one `#[test]` per case in spec/tests.json, so each conformance case
//! appears separately in `cargo test` output.
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

    let known_top_level = [
        "$schema",
        "version",
        "description",
        "now",
        "_eval_assertion_types",
        "_behavioral_notes",
        "parse",
        "parse_errors",
        "eval",
        "eval_errors",
        "cron",
        "invariants",
    ];
    for key in spec.as_object().expect("spec should be an object").keys() {
        if !known_top_level.contains(&key.as_str()) {
            emit_unknown(&mut f, key);
        }
    }

    for (section, _) in sections(&spec["parse"]) {
        for (i, case) in iter_tests(&spec["parse"][section]).enumerate() {
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

    for (i, case) in iter_tests(&spec["parse_errors"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(&mut f, &format!("parse_error_{name}"), "run_parse_error", i);
    }

    // Sections not named here hold nextFrom cases (spec/README.md, "Writing a runner").
    for (section, data) in sections(&spec["eval"]) {
        let runner = match section {
            "matches" => "run_eval_matches",
            "occurrences" => "run_eval_occurrences",
            "between" => "run_eval_between",
            "previous_from" => "run_eval_previous_from",
            _ => "run_eval",
        };
        for (i, case) in iter_tests(data).enumerate() {
            let name = test_name(case, i);
            emit(
                &mut f,
                &format!("eval_{section}_{name}"),
                runner,
                section,
                i,
            );
        }
    }

    for (i, case) in iter_tests(&spec["eval_errors"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(&mut f, &format!("eval_error_{name}"), "run_eval_error", i);
    }

    for (section, data) in sections(&spec["cron"]) {
        let runner = match section {
            "to_cron" => "run_cron_to_cron",
            "to_cron_errors" => "run_cron_to_cron_error",
            "from_cron" => "run_cron_from_cron",
            "from_cron_errors" => "run_cron_from_cron_error",
            "roundtrip" => "run_cron_roundtrip",
            _ => {
                emit_unknown(&mut f, &format!("cron.{section}"));
                continue;
            }
        };
        for (i, case) in iter_tests(data).enumerate() {
            let name = test_name(case, i);
            emit(
                &mut f,
                &format!("cron_{section}_{name}"),
                runner,
                section,
                i,
            );
        }
    }

    for (i, case) in iter_tests(&spec["invariants"]).enumerate() {
        let name = test_name(case, i);
        emit_flat(&mut f, &format!("invariant_{name}"), "run_invariants", i);
    }
}

/// The sections of a category, skipping its `description`.
fn sections(category: &serde_json::Value) -> impl Iterator<Item = (&str, &serde_json::Value)> {
    category
        .as_object()
        .expect("category should be an object")
        .iter()
        .filter(|(key, _)| key.as_str() != "description")
        .map(|(key, value)| (key.as_str(), value))
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

fn emit_unknown(f: &mut fs::File, section: &str) {
    let fn_name = format!("unknown_section_{}", sanitize(section));
    writeln!(f, "#[test]").unwrap();
    writeln!(
        f,
        "fn {fn_name}() {{ panic!(\"spec section '{section}' is not known to this runner\"); }}"
    )
    .unwrap();
}

fn emit_flat(f: &mut fs::File, fn_name: &str, runner: &str, index: usize) {
    writeln!(f, "#[test]").unwrap();
    writeln!(f, "fn {fn_name}() {{ {runner}({index}); }}").unwrap();
}
