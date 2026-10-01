use std::io::{self, BufRead, Write};
use std::panic::{self, AssertUnwindSafe};

use hron::{Schedule, ScheduleError};
use jiff::Zoned;
use serde_json::{json, Value};

fn main() {
    panic::set_hook(Box::new(|_| {}));
    let mut stdout = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let case: Value = serde_json::from_str(&line.expect("stdin")).expect("a JSON case");
        let mut outcome = match panic::catch_unwind(AssertUnwindSafe(|| evaluate(&case))) {
            Ok(Ok(result)) => json!({ "ok": true, "result": result }),
            Ok(Err(error)) => json!({ "ok": false, "error": details(&error) }),
            Err(panic) => {
                json!({ "ok": false, "error": { "kind": "crash", "message": message(panic) } })
            }
        };
        outcome["id"] = case["id"].clone();
        writeln!(stdout, "{outcome}").expect("stdout");
        stdout.flush().expect("stdout");
    }
}

fn evaluate(case: &Value) -> Result<Value, ScheduleError> {
    let expr = case["expr"].as_str().expect("expr");
    let time = |field: &str| -> Zoned { case[field].as_str().expect(field).parse().expect(field) };
    let n = || case["n"].as_u64().expect("n") as usize;
    if case["op"] == "fromCron" {
        return Ok(json!(Schedule::from_cron(expr)?.to_string()));
    }
    let schedule = Schedule::parse(expr)?;
    Ok(match case["op"].as_str().expect("op") {
        "parse" => json!(schedule.to_string()),
        "toCron" => json!(schedule.to_cron()?),
        "next" => json!(schedule.next_from(&time("now"))?.map(|t| t.to_string())),
        "nextN" => strings(schedule.next_n_from(&time("now"), n())?),
        "prev" => json!(schedule.previous_from(&time("now"))?.map(|t| t.to_string())),
        "matches" => json!(schedule.matches(&time("datetime"))?),
        "between" => strings(
            schedule
                .between(&time("from"), &time("to"))
                .collect::<Result<_, _>>()?,
        ),
        "occurrences" => strings(
            schedule
                .occurrences(&time("from"))
                .take(n())
                .collect::<Result<_, _>>()?,
        ),
        op => panic!("unknown op {op}"),
    })
}

fn strings(times: Vec<Zoned>) -> Value {
    json!(times.iter().map(Zoned::to_string).collect::<Vec<_>>())
}

fn details(error: &ScheduleError) -> Value {
    let (kind, span, suggestion) = match error {
        ScheduleError::Lex { span, .. } => ("lex", Some(span), None),
        ScheduleError::Parse {
            span, suggestion, ..
        } => ("parse", Some(span), suggestion.as_deref()),
        ScheduleError::Eval { .. } => ("eval", None, None),
        ScheduleError::Cron { .. } => ("cron", None, None),
        _ => ("unknown", None, None),
    };
    json!({
        "kind": kind,
        "message": error.to_string(),
        "span": span.map(|span| [span.start, span.end]),
        "suggestion": suggestion,
    })
}

fn message(panic: Box<dyn std::any::Any + Send>) -> String {
    panic
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| panic.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default()
}
