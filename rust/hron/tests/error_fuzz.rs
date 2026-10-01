use hron::error::Span;
use hron::{Schedule, ScheduleError};
use regex::{Captures, Regex};
use serde_json::Value;
use std::panic;

const INPUTS: usize = 6000;
const SEED: u64 = 0x5EED_4A0E;

const WHAT: &str = concat!(
    r"'every' or 'on'",
    r"|'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
    r"|a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)",
    r"|'at'|a time \(HH:MM\)|'from'|'to'",
    r"|'day', 'weekday', 'weekend' or a day name",
    r"|'on'|a day name|'the'",
    r"|a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
    r"|'day', 'weekday' or a day name",
    r"|'nearest'|'weekday'|a day such as 15th",
    r"|a month name or 'the'",
    r"|a day such as 15th, 'last' or an ordinal such as 'first'",
    r"|'weekday' or a day name",
    r"|'of'|a month name|a day number",
    r"|a date \(YYYY-MM-DD, or a month and day\)|a date \(YYYY-MM-DD\)|a timezone",
);
const MONTH: &str = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec";
const DAY: &str = r"[0-9]+(?i:st|nd|rd|th)?";
const TIME: &str = r"[0-9]{1,2}:[0-9]{2}";

const CLAUSE_ORDER: [&str; 5] = ["except", "until", "starting", "during", "in"];
const TOKEN_SEPARATORS: [char; 4] = [' ', '\t', '\r', '\n'];

struct Failure<'a> {
    input: &'a str,
    span: Span,
    spanned: String,
}

type Check = fn(&Captures, &Failure) -> Result<(), String>;

struct Template {
    kind: &'static str,
    regex: Regex,
    check: Check,
}

fn ensure(holds: bool, problem: impl FnOnce() -> String) -> Result<(), String> {
    if holds {
        Ok(())
    } else {
        Err(problem())
    }
}

/// Saturates, since a digit run can be thousands of digits long.
fn value(text: &str) -> u64 {
    text.bytes().take_while(u8::is_ascii_digit).fold(0, |n, d| {
        n.saturating_mul(10).saturating_add(u64::from(d - b'0'))
    })
}

fn group<'t>(captures: &Captures<'t>, name: &str) -> &'t str {
    captures.name(name).map_or("", |m| m.as_str())
}

fn no_check(_: &Captures, _: &Failure) -> Result<(), String> {
    Ok(())
}

/// From spec/README.md, "Lex errors" and "Parse errors". A `span` group must
/// equal the spanned text; every other group is read by its template's check.
fn templates() -> Vec<Template> {
    let template = |kind, pattern: String, check: Check| Template {
        kind,
        regex: Regex::new(&pattern).unwrap(),
        check,
    };
    vec![
        template(
            "lex",
            r"^unexpected character '(?P<span>[!-&(-~])'$".into(),
            |_, f| {
                let c = f.spanned.chars().next().unwrap_or(' ');
                ensure(!c.is_ascii_alphanumeric() && c != ',', || {
                    format!("'{c}' starts a token, so it is never unexpected")
                })
            },
        ),
        template(
            "lex",
            r"^unexpected character U\+(?P<code>[0-9A-F]{4,})$".into(),
            |c, f| {
                let shown = u32::from_str_radix(group(c, "code"), 16).unwrap();
                let quotable = (0x21..=0x7e).contains(&shown) && shown != 0x27;
                let mut chars = f.spanned.chars();
                ensure(
                    chars.next().map(u32::from) == Some(shown) && chars.next().is_none() && !quotable,
                    || format!("U+{} does not describe '{}'", group(c, "code"), f.spanned),
                )
            },
        ),
        template(
            "lex",
            r"^unknown keyword '(?P<span>[A-Za-z][A-Za-z0-9_]*)'$".into(),
            no_check,
        ),
        template(
            "lex",
            r"^time must be H:MM or HH:MM, got (?P<span>(?P<hour>[0-9]+):(?P<minute>[0-9]*))$".into(),
            |c, _| {
                let (hour, minute) = (group(c, "hour"), group(c, "minute"));
                ensure(!(1..=2).contains(&hour.len()) || minute.len() != 2, || {
                    format!("{hour}:{minute} is H:MM or HH:MM")
                })
            },
        ),
        template(
            "lex",
            r"^time must be 00:00-23:59, got (?P<span>(?P<hour>[0-9]{1,2}):(?P<minute>[0-9]{2}))$".into(),
            |c, _| {
                let (hour, minute) = (value(group(c, "hour")), value(group(c, "minute")));
                ensure(hour > 23 || minute > 59, || format!("{hour}:{minute} is in range"))
            },
        ),
        template(
            "lex",
            r"^number must be at most 2147483647$".into(),
            |_, f| {
                let digits = !f.spanned.is_empty() && f.spanned.bytes().all(|b| b.is_ascii_digit());
                ensure(digits && value(&f.spanned) > 2147483647, || {
                    format!("'{}' is not digits above 2147483647", f.spanned)
                })
            },
        ),
        template("parse", r"^empty expression$".into(), |_, f| {
            let blank = f.input.trim_matches(TOKEN_SEPARATORS).is_empty();
            ensure(blank && f.span == Span::new(0, 0), || {
                format!("empty expression with span {} for {:?}", f.span, f.input)
            })
        }),
        template(
            "parse",
            format!(r"^expected (?:{WHAT}), got (?:'(?P<span>.+)'|(?P<end>end of input))$"),
            |c, f| {
                if c.name("end").is_none() {
                    return Ok(());
                }
                let end = f.input.trim_end_matches(TOKEN_SEPARATORS).chars().count();
                ensure(f.span == Span::new(end, end), || {
                    format!("end of input at {}, expected {end}..{end}", f.span)
                })
            },
        ),
        template(
            "parse",
            r"^interval must be 1-2147483647, got (?P<span>[0-9]+)$".into(),
            |_, f| ensure(value(&f.spanned) == 0, || format!("interval {} is valid", f.spanned)),
        ),
        template(
            "parse",
            format!(r"^day must be 1-31, got (?P<span>{DAY})$"),
            |_, f| {
                let day = value(&f.spanned);
                ensure(day == 0 || day > 31, || format!("day {day} is within 1-31"))
            },
        ),
        template(
            "parse",
            format!(r"^day must be 1-(?P<max>[0-9]+) for (?P<month>{MONTH}), got (?P<span>{DAY})$"),
            |c, f| {
                let month = group(c, "month");
                let length = match month {
                    "feb" => 29,
                    "apr" | "jun" | "sep" | "nov" => 30,
                    _ => 31,
                };
                let (max, day) = (value(group(c, "max")), value(&f.spanned));
                ensure(max == length && day > max && day <= 31, || {
                    format!("day {day} against 1-{max} for {month}")
                })
            },
        ),
        template(
            "parse",
            format!(r"^day range must not run backwards: (?P<a>{DAY}) to (?P<b>{DAY})$"),
            |c, f| {
                let (a, b) = (group(c, "a"), group(c, "b"));
                let spans_both = f.spanned.starts_with(a) && f.spanned.ends_with(b);
                ensure(spans_both && value(a) > value(b), || {
                    format!("{a} to {b} against the span '{}'", f.spanned)
                })
            },
        ),
        template(
            "parse",
            format!(
                r"^time window must not run backwards: (?P<from>{TIME}) to (?P<to>{TIME}) \(a window cannot cross midnight\)$"
            ),
            |c, f| {
                let (from, to) = (group(c, "from"), group(c, "to"));
                let minutes = |t: &str| {
                    let (hour, minute) = t.split_once(':').unwrap();
                    value(hour) * 60 + value(minute)
                };
                let spans_both = f.spanned.starts_with(from) && f.spanned.ends_with(to);
                ensure(spans_both && minutes(from) > minutes(to), || {
                    format!("{from} to {to} against the span '{}'", f.spanned)
                })
            },
        ),
        template(
            "parse",
            r"^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?P<span>[0-9]{4}-[0-9]{2}-[0-9]{2})$".into(),
            |_, f| {
                let calendar = f.spanned.parse::<jiff::civil::Date>().is_ok_and(|d| d.year() >= 1);
                ensure(!calendar, || format!("{} is a calendar date", f.spanned))
            },
        ),
        template(
            "parse",
            r"^timezone must be UTC or an Area/Location name such as America/New_York, got (?P<span>.+)$".into(),
            no_check,
        ),
        template(
            "parse",
            r"^duplicate '(?P<keyword>except|until|starting|during|in)' clause$".into(),
            |c, f| {
                ensure(group(c, "keyword") == f.spanned.to_ascii_lowercase(), || {
                    format!("duplicate '{}' but the span holds '{}'", group(c, "keyword"), f.spanned)
                })
            },
        ),
        template(
            "parse",
            r"^'(?P<keyword>[a-z]+)' must come before '(?P<last>[a-z]+)'$".into(),
            |c, f| {
                let (keyword, last) = (group(c, "keyword"), group(c, "last"));
                let order = |kw| CLAUSE_ORDER.iter().position(|&k| k == kw);
                let earlier = matches!((order(keyword), order(last)), (Some(k), Some(l)) if k < l);
                ensure(earlier && keyword == f.spanned.to_ascii_lowercase(), || {
                    format!("'{keyword}' before '{last}' with the span '{}'", f.spanned)
                })
            },
        ),
        template(
            "parse",
            r"^unexpected '(?P<span>.+)' after the schedule$".into(),
            no_check,
        ),
        template(
            "parse",
            format!(
                r"^until (?P<month>{MONTH}) (?P<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date$"
            ),
            |c, f| {
                let words: Vec<&str> = f.spanned.split(TOKEN_SEPARATORS).filter(|w| !w.is_empty()).collect();
                let ends_at_day = !f.spanned.ends_with(TOKEN_SEPARATORS);
                let matches_message = ends_at_day && match words[..] {
                    [until, month, day] => {
                        until.eq_ignore_ascii_case("until")
                            && month.to_ascii_lowercase().starts_with(group(c, "month"))
                            && day.starts_with(|c: char| c.is_ascii_digit())
                            && value(day).to_string() == group(c, "day")
                    }
                    _ => false,
                };
                ensure(matches_message, || {
                    format!("the span '{}' is not 'until {} {}'", f.spanned, group(c, "month"), group(c, "day"))
                })
            },
        ),
    ]
}

const FRAGMENTS: &[&str] = &[
    "every",
    "on",
    "at",
    "from",
    "to",
    "in",
    "IN",
    "of",
    "the",
    "last",
    "except",
    "until",
    "starting",
    "during",
    "nearest",
    "next",
    "previous",
    "day",
    "Days",
    "weekdays",
    "weekend",
    "week",
    "month",
    "years",
    "min",
    "hrs",
    "monday",
    "FRI",
    "jan",
    "february",
    "first",
    "fifth",
    "0",
    "1",
    "00",
    "15th",
    "31ST",
    "2nd",
    "2147483647",
    "2147483648",
    "99999999999999999999",
    "09:00",
    "9:5",
    "24:00",
    "9:",
    "17:30",
    "2026-02-28",
    "2026-02-30",
    "0000-01-01",
    "12026-03-15",
    ",",
    ":",
    "-",
    "/",
    "'",
    "\"",
    "#",
    "~",
    "_",
    "UTC",
    "America/New_York",
    "Nope/Zone",
    "Europe/\u{130}stanbul",
    "\u{e9}",
    "e\u{301}",
    "\u{212a}",
    "\u{a0}",
    "\u{2028}",
    "\u{feff}",
    "\u{ff10}",
    "\u{1f600}",
    "\u{10ffff}",
    "\u{1d7d8}",
    "\0",
    "\u{b}",
    "\u{c}",
    "\u{7f}",
    "\u{1b}",
];
const SEPARATORS: &[&str] = &["", " ", " ", " ", "  ", "\t", "\r\n", "\n"];

struct Rng(u64);

impl Rng {
    // SplitMix64: a fixed seed gives the same inputs on every platform.
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.below(items.len())]
    }
}

fn corpus() -> Vec<String> {
    let spec: Value = serde_json::from_str(include_str!("../../../spec/tests.json")).unwrap();
    let parse_inputs = spec["parse"]
        .as_object()
        .unwrap()
        .values()
        .filter_map(|section| section["tests"].as_array())
        .flatten();
    let error_inputs = spec["parse_errors"]["tests"].as_array().unwrap().iter();
    parse_inputs
        .chain(error_inputs)
        .map(|case| case["input"].as_str().unwrap().to_string())
        .collect()
}

fn random_text(rng: &mut Rng) -> String {
    let mut out = String::new();
    for _ in 0..=rng.below(12) {
        out.push_str(rng.pick(SEPARATORS));
        out.push_str(rng.pick(FRAGMENTS));
    }
    out
}

fn mutate(rng: &mut Rng, input: &str) -> String {
    let mut words: Vec<String> = input.split(' ').map(String::from).collect();
    let i = rng.below(words.len());
    match rng.below(7) {
        0 => {
            words.remove(i);
        }
        1 => {
            let j = rng.below(words.len());
            words.swap(i, j);
        }
        2 => {
            let copy = words[i].clone();
            words.insert(rng.below(words.len() + 1), copy);
        }
        3 => {
            let chars: Vec<char> = input.chars().collect();
            return chars[..rng.below(chars.len() + 1)].iter().collect();
        }
        4 => words[i] = words[i].to_ascii_uppercase(),
        5 => words[i] = rng.pick(FRAGMENTS).to_string(),
        _ => {
            let fragment = rng.pick(FRAGMENTS);
            let at = rng.below(words[i].chars().count() + 1);
            let mut chars: Vec<char> = words[i].chars().collect();
            chars.splice(at..at, fragment.chars());
            words[i] = chars.into_iter().collect();
        }
    }
    words.join(" ")
}

const CLAUSES: &[&str] = &[
    "except dec 25",
    "except 2026-12-25, jan 1",
    "until 2027-12-31",
    "until dec 31",
    "starting 2026-01-01",
    "during jan, jul",
    "in UTC",
    "IN America/New_York",
];

fn with_clauses(rng: &mut Rng, input: &str) -> String {
    let mut out = input.to_string();
    for _ in 0..=rng.below(4) {
        out.push(' ');
        out.push_str(rng.pick(CLAUSES));
    }
    out
}

fn generate(rng: &mut Rng, corpus: &[String]) -> String {
    match rng.below(4) {
        0 => random_text(rng),
        1 => {
            let input = corpus[rng.below(corpus.len())].clone();
            with_clauses(rng, &input)
        }
        _ => {
            let mut input = corpus[rng.below(corpus.len())].clone();
            for _ in 0..rng.below(4) {
                input = mutate(rng, &input);
            }
            input
        }
    }
}

fn check(input: &str, error: &ScheduleError, templates: &[Template]) -> Result<usize, String> {
    let (kind, message, span, error_input, suggestion) = match error {
        ScheduleError::Lex {
            message,
            span,
            input,
        } => ("lex", message, *span, input, None),
        ScheduleError::Parse {
            message,
            span,
            input,
            suggestion,
        } => ("parse", message, *span, input, suggestion.as_deref()),
        other => return Err(format!("neither lex nor parse: {other:?}")),
    };
    ensure(!Schedule::validate(input), || "validate is true".into())?;
    ensure(error_input == input, || {
        format!("error input is {error_input:?}")
    })?;
    let chars: Vec<char> = input.chars().collect();
    ensure(span.start <= span.end && span.end <= chars.len(), || {
        format!("span {span} outside 0..={}", chars.len())
    })?;
    let failure = Failure {
        input,
        span,
        spanned: chars[span.start..span.end].iter().collect(),
    };

    let (index, captures) = templates
        .iter()
        .enumerate()
        .filter(|(_, template)| template.kind == kind)
        .find_map(|(i, template)| template.regex.captures(message).map(|c| (i, c)))
        .ok_or_else(|| format!("{kind} message '{message}' matches no template"))?;
    if let Some(echoed) = captures.name("span") {
        ensure(echoed.as_str() == failure.spanned, || {
            format!(
                "message echoes '{}' but the span holds '{}'",
                echoed.as_str(),
                failure.spanned
            )
        })?;
    }
    (templates[index].check)(&captures, &failure)?;

    let named_until = message.starts_with("until ");
    let expected_suggestion = named_until.then(|| {
        format!(
            "until {} {} starting YYYY-MM-DD",
            group(&captures, "month"),
            group(&captures, "day")
        )
    });
    ensure(
        suggestion.map(str::to_string) == expected_suggestion,
        || format!("suggestion {suggestion:?}, expected {expected_suggestion:?}"),
    )?;

    let rich = error.display_rich();
    ensure(
        rich.split('\n').count() == 3 && rich.starts_with(&format!("error: {message}\n")),
        || format!("displayRich is not three lines: {rich:?}"),
    )?;
    Ok(index)
}

#[test]
fn generated_inputs_fail_only_with_spec_errors() {
    let templates = templates();
    let corpus = corpus();
    let mut rng = Rng(SEED);
    let mut hits = vec![0; templates.len()];
    let mut parsed = 0;
    let mut failures = Vec::new();

    for _ in 0..INPUTS {
        let input = generate(&mut rng, &corpus);
        match panic::catch_unwind(|| Schedule::parse(&input)) {
            Err(_) => failures.push(format!("{input:?}: parse panicked")),
            Ok(Ok(_)) => parsed += 1,
            Ok(Err(error)) => match check(&input, &error, &templates) {
                Ok(index) => hits[index] += 1,
                Err(problem) => failures.push(format!("{input:?}: {problem}")),
            },
        }
    }

    assert!(
        failures.is_empty(),
        "{} failures, first ones:\n{}",
        failures.len(),
        failures[..failures.len().min(20)].join("\n")
    );
    assert!(
        parsed > INPUTS / 20,
        "only {parsed} inputs parsed; the generator has drifted"
    );
    let unused: Vec<_> = templates
        .iter()
        .zip(&hits)
        .filter(|(_, &count)| count == 0)
        .map(|(template, _)| template.regex.as_str())
        .collect();
    assert!(
        unused.is_empty(),
        "templates no input produced: {unused:#?}"
    );
}
