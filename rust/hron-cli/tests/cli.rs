use assert_cmd::Command;
use predicates::prelude::*;

fn hron() -> Command {
    Command::cargo_bin("hron").unwrap()
}

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
        .arg("every month on the first monday at 10:00 in UTC")
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
        .failure()
        .stderr("error: unknown keyword 'blorp'\n  every blorp at 09:00\n        ^^^^^\n");
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
fn test_to_cron_yearly() {
    hron()
        .args(["--to-cron", "every year on dec 25 at 00:00"])
        .assert()
        .success()
        .stdout("0 0 25 12 *\n");
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

#[test]
fn test_json_output() {
    hron()
        .args(["-n", "3", "--json", "every day at 09:00 in UTC"])
        .assert()
        .success()
        .stdout(predicate::str::starts_with("["));
}

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
fn test_to_cron_multi_time() {
    hron()
        .args(["--to-cron", "every day at 9:00, 17:00"])
        .assert()
        .success()
        .stdout("0 9,17 * * *\n");
}

#[test]
fn test_to_cron_during() {
    hron()
        .args(["--to-cron", "every day at 9:00 during jan"])
        .assert()
        .success()
        .stdout("0 9 * 1 *\n");
}

#[test]
fn test_to_cron_day_range() {
    hron()
        .args(["--to-cron", "every month on the 1st to 5th at 9:00"])
        .assert()
        .success()
        .stdout("0 9 1-5 * *\n");
}

#[test]
fn test_no_expression() {
    hron().assert().failure();
}

fn occurrences_between(from: &str, to: &str, expression: &str) -> assert_cmd::assert::Assert {
    hron()
        .args(["--from", from, "--to", to, expression])
        .assert()
}

#[test]
fn writes_timestamps_in_the_schedule_zone_with_seconds_and_offset() {
    occurrences_between(
        "2026-02-06T21:00:00+09:00[Asia/Tokyo]",
        "2026-02-07T15:00:00+01:00[Europe/Berlin]",
        "every day at 09:00 in America/New_York",
    )
    .success()
    .stdout("2026-02-06T09:00:00-05:00[America/New_York]\n2026-02-07T09:00:00-05:00[America/New_York]\n");
}

#[test]
fn writes_utc_as_plus_zero_not_z() {
    occurrences_between(
        "2026-02-06T03:00:00Z",
        "2026-02-07T12:00:00Z",
        "every day at 09:00",
    )
    .success()
    .stdout("2026-02-06T09:00:00+00:00[UTC]\n2026-02-07T09:00:00+00:00[UTC]\n");
}

#[test]
fn writes_json_in_the_same_form() {
    hron()
        .args([
            "--json",
            "--from",
            "2026-02-05T20:00:00Z",
            "--to",
            "2026-02-06T03:00:00Z",
            "every day at 09:00 in Asia/Tokyo",
        ])
        .assert()
        .success()
        .stdout("[\"2026-02-06T09:00:00+09:00[Asia/Tokyo]\"]\n");
}

// Each names 2026-02-06T03:00:00Z, so the next 09:00 UTC is the same day.
#[test]
fn reads_every_accepted_form_as_its_instant() {
    for from in [
        "2026-02-06T12:00:00+09:00[Asia/Tokyo]",
        "2026-02-06T03:00:00Z",
        "2026-02-06t03:00:00.000z",
        "2026-02-06T03:00:00+00:00[Asia/Tokyo]",
        "2026-02-06T12:00:00+09:00[!Asia/Tokyo]",
        "2026-02-06T03:00:00Z[!Asia/Tokyo]",
        "2026-02-06T03:00:00+00:00[u-ca=hebrew]",
        "2026-02-06T12:00:00+09:00[Asia/Tokyo][u-ca=japanese]",
        "2026-02-06T12:00:00+09:00[+09:00]",
        "+002026-02-06T03:00:00Z",
    ] {
        occurrences_between(from, "2026-02-06T23:00:00Z", "every day at 09:00")
            .success()
            .stdout("2026-02-06T09:00:00+00:00[UTC]\n");
    }
}

#[test]
fn lets_the_offset_decide_the_instant_over_a_disagreeing_zone() {
    occurrences_between(
        "2026-02-06T08:59:00+00:00[Asia/Tokyo]",
        "2026-02-06T09:00:00+00:00[America/New_York]",
        "every day at 09:00",
    )
    .success()
    .stdout("2026-02-06T09:00:00+00:00[UTC]\n");
}

#[test]
fn exits_with_status_2_on_a_timestamp_it_cannot_read() {
    for bad in [
        "2026-02-06T12:00:00[Asia/Tokyo]",
        "2026-02-06T03:00:00+00:00[!Asia/Tokyo]",
        "2026-02-06T03:00:00+00:00[Nope/Zone]",
        "2026-02-06T03:00:00+00:00[!u-ca=hebrew]",
        "2026-02-06",
        "tomorrow",
        "+010000-01-01T00:00:00[UTC]",
        "+010000-01-01T00:00:00+00:00[Nope/Zone]",
        "9999-12-31T12:00:00+00:00[Nope/Zone]",
    ] {
        hron()
            .args(["--from", bad, "every day at 09:00"])
            .assert()
            .code(2)
            .stdout("")
            .stderr(predicate::str::starts_with(format!(
                "error: --from: invalid timestamp \"{bad}\": "
            )));
    }
    occurrences_between("2026-02-06T03:00:00Z", "noon", "every day at 09:00")
        .code(2)
        .stderr(predicate::str::starts_with("error: --to: "));
}

#[test]
fn finds_nothing_for_a_timestamp_outside_the_supported_range() {
    for from in [
        "+010000-01-01T00:00:00Z",
        "-010000-01-01T00:00:00Z",
        "+275760-09-13T00:00:00.000Z",
        "9999-12-31T12:00:00+00:00[UTC]",
        "-009999-01-01T00:00:00+00:00[UTC]",
        "0001-01-01T00:00:00Z",
    ] {
        hron()
            .args(["--from", from, "every day at 09:00"])
            .assert()
            .success()
            .stdout("")
            .stderr("no occurrences in range\n");
    }
    occurrences_between(
        "2026-02-06T03:00:00Z",
        "+010000-01-01T00:00:00Z",
        "every day at 09:00",
    )
    .success()
    .stdout("")
    .stderr("no occurrences in range\n");
}

#[test]
fn exits_with_status_1_on_a_hron_error() {
    hron().arg("every blorp").assert().code(1);
}

#[test]
fn exits_with_status_2_without_an_expression() {
    hron().assert().code(2);
}

#[test]
fn exits_quietly_when_the_reader_has_gone() {
    let (reader, writer) = std::io::pipe().unwrap();
    drop(reader);
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_hron"))
        .args(["-n", "3", "every day at 09:00"])
        .stdout(writer)
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&output.stderr), "");
    assert!(output.status.success(), "{:?}", output.status);
}
