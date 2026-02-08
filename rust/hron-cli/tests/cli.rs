use assert_cmd::Command;
use predicates::prelude::*;

fn hron() -> Command {
    Command::cargo_bin("hron").unwrap()
}

// ============================================================
// Basic expressions
// ============================================================

#[test]
fn test_basic_expression() {
    hron()
        .arg("every day at 09:00 in UTC")
        .assert()
        .success()
        .stdout(predicate::str::contains("T09:00:00"));
}

#[test]
fn test_weekday_expression() {
    hron()
        .arg("every weekday at 09:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_interval_expression() {
    hron()
        .arg("every 30 min from 09:00 to 17:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_ordinal_expression() {
    hron()
        .arg("first monday of every month at 10:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_yearly_expression() {
    hron()
        .arg("every year on dec 25 at 00:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_monthly_expression() {
    hron()
        .arg("every month on the 1st at 09:00 in UTC")
        .assert()
        .success()
        .stdout(predicate::str::contains("T09:00:00"));
}

#[test]
fn test_single_date_expression() {
    hron()
        .arg("on 2026-12-25 at 09:00 in UTC")
        .assert()
        .success()
        .stdout(predicate::str::contains("2026-12-25"));
}

#[test]
fn test_week_repeat_expression() {
    hron()
        .args([
            "-n",
            "3",
            "every 2 weeks on monday at 9:00 starting 2026-02-02 in UTC",
        ])
        .assert()
        .success();
}

// ============================================================
// Trailing clause expressions
// ============================================================

#[test]
fn test_except_expression() {
    hron()
        .arg("every weekday at 09:00 except dec 25, jan 1 in UTC")
        .assert()
        .success();
}

#[test]
fn test_until_expression() {
    hron()
        .arg("every day at 09:00 until 2026-12-31 in UTC")
        .assert()
        .success();
}

#[test]
fn test_starting_expression() {
    hron()
        .args([
            "-n",
            "3",
            "every 2 weeks on monday at 9:00 starting 2026-01-05 in UTC",
        ])
        .assert()
        .success();
}

// ============================================================
// Flags
// ============================================================

#[test]
fn test_n_flag() {
    hron()
        .args(["-n", "3", "every day at 09:00 in UTC"])
        .assert()
        .success()
        .stdout(predicate::str::contains("T09:00:00"));
}

#[test]
fn test_check_valid() {
    hron()
        .args(["--check", "every day at 09:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("valid"));
}

#[test]
fn test_check_invalid() {
    hron()
        .args(["--check", "every blorp at 09:00"])
        .assert()
        .failure();
}

#[test]
fn test_parse_json() {
    hron()
        .args(["--parse", "every weekday at 9:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"kind\""))
        .stdout(predicate::str::contains("\"every\""));
}

#[test]
fn test_parse_json_yearly() {
    hron()
        .args(["--parse", "every year on dec 25 at 00:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"yearly\""));
}

#[test]
fn test_parse_json_with_except() {
    hron()
        .args(["--parse", "every weekday at 9:00 except dec 25"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"except\""));
}

// ============================================================
// Cron conversion
// ============================================================

#[test]
fn test_to_cron() {
    hron()
        .args(["--to-cron", "every weekday at 9:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("0 9 * * 1-5"));
}

#[test]
fn test_to_cron_not_expressible() {
    hron()
        .args(["--to-cron", "every 2 weeks on monday at 9:00"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not expressible"));
}

#[test]
fn test_to_cron_yearly_fails() {
    hron()
        .args(["--to-cron", "every year on dec 25 at 00:00"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not expressible"));
}

#[test]
fn test_from_cron() {
    hron()
        .args(["--from-cron", "0 9 * * 1-5"])
        .assert()
        .success()
        .stdout(predicate::str::contains("every weekday at 09:00"));
}

#[test]
fn test_explain() {
    hron()
        .args(["--explain", "0 9 * * 1-5"])
        .assert()
        .success()
        .stdout(predicate::str::contains("weekday"));
}

// ============================================================
// Output formats
// ============================================================

#[test]
fn test_json_output() {
    hron()
        .args(["-n", "3", "--json", "every day at 09:00 in UTC"])
        .assert()
        .success()
        .stdout(predicate::str::starts_with("["));
}

// ============================================================
// New features: multi-time, during, day ranges
// ============================================================

#[test]
fn test_multi_time_expression() {
    hron()
        .arg("every day at 09:00, 17:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_during_expression() {
    hron()
        .arg("every weekday at 09:00 during jan, jun in UTC")
        .assert()
        .success();
}

#[test]
fn test_day_range_expression() {
    hron()
        .arg("every month on the 1st to 15th at 09:00 in UTC")
        .assert()
        .success();
}

#[test]
fn test_parse_json_multi_time() {
    hron()
        .args(["--parse", "every day at 9:00, 17:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"times\""));
}

#[test]
fn test_parse_json_during() {
    hron()
        .args(["--parse", "every day at 9:00 during jan"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"during\""));
}

#[test]
fn test_to_cron_multi_time_fails() {
    hron()
        .args(["--to-cron", "every day at 9:00, 17:00"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not expressible"));
}

#[test]
fn test_to_cron_during_fails() {
    hron()
        .args(["--to-cron", "every day at 9:00 during jan"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("not expressible"));
}

#[test]
fn test_to_cron_day_range() {
    hron()
        .args(["--to-cron", "every month on the 1st to 5th at 9:00"])
        .assert()
        .success()
        .stdout(predicate::str::contains("0 9 1,2,3,4,5 * *"));
}

// ============================================================
// Error cases
// ============================================================

#[test]
fn test_no_expression() {
    hron().assert().failure();
}
