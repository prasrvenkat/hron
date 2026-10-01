use hron::{Schedule, ScheduleError};
use regex::Regex;
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

/// From spec/README.md, "Lex errors" and "Parse errors".
/// `(?P<span>...)` must equal the input's code points in the span; when the
/// template has that group but it did not take part, the span must be empty.
/// `(?P<keyword>...)` must equal the span's text in lowercase.
fn templates() -> Vec<(&'static str, Regex)> {
    let lex = [
        r"^unexpected character '(?P<span>[!-&(-~])'$".to_string(),
        r"^unexpected character U\+(?P<code>[0-9A-F]{4,})$".to_string(),
        r"^unknown keyword '(?P<span>[A-Za-z][A-Za-z0-9_]*)'$".to_string(),
        r"^time must be H:MM or HH:MM, got (?P<span>[0-9]+:[0-9]*)$".to_string(),
        format!(r"^time must be 00:00-23:59, got (?P<span>{TIME})$"),
        r"^number must be at most 2147483647$".to_string(),
    ];
    let parse = [
        r"^empty expression$".to_string(),
        format!(r"^expected (?:{WHAT}), got (?:'(?P<span>.+)'|end of input)$"),
        r"^interval must be 1-2147483647, got (?P<span>[0-9]+)$".to_string(),
        format!(r"^day must be 1-31, got (?P<span>{DAY})$"),
        format!(r"^day must be 1-(?:29|30) for (?:{MONTH}), got (?P<span>{DAY})$"),
        format!(r"^day range must not run backwards: {DAY} to {DAY}$"),
        format!(
            r"^time window must not run backwards: {TIME} to {TIME} \(a window cannot cross midnight\)$"
        ),
        r"^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?P<span>[0-9]{4}-[0-9]{2}-[0-9]{2})$".to_string(),
        r"^timezone must be UTC or an Area/Location name such as America/New_York, got (?P<span>.+)$".to_string(),
        r"^duplicate '(?P<keyword>except|until|starting|during|in)' clause$".to_string(),
        r"^'(?P<keyword>except|until|starting|during)' must come before '(?:until|starting|during|in)'$".to_string(),
        r"^unexpected '(?P<span>.+)' after the schedule$".to_string(),
        format!(r"^until (?P<month>{MONTH}) (?P<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date$"),
    ];
    let compile = |kind, pattern: String| (kind, Regex::new(&pattern).unwrap());
    lex.into_iter()
        .map(|p| compile("lex", p))
        .chain(parse.into_iter().map(|p| compile("parse", p)))
        .collect()
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

fn generate(rng: &mut Rng, corpus: &[String]) -> String {
    match rng.below(3) {
        0 => random_text(rng),
        _ => {
            let mut input = corpus[rng.below(corpus.len())].clone();
            for _ in 0..rng.below(4) {
                input = mutate(rng, &input);
            }
            input
        }
    }
}

fn check(input: &str, error: &ScheduleError, templates: &[(&str, Regex)]) -> Result<usize, String> {
    let (kind, message, span, suggestion) = match error {
        ScheduleError::Lex { message, span, .. } => ("lex", message, span, None),
        ScheduleError::Parse {
            message,
            span,
            suggestion,
            ..
        } => ("parse", message, span, suggestion.as_deref()),
        other => return Err(format!("neither lex nor parse: {other:?}")),
    };
    let chars: Vec<char> = input.chars().collect();
    if span.start > span.end || span.end > chars.len() {
        return Err(format!("span {span} outside 0..={}", chars.len()));
    }
    let spanned: String = chars[span.start..span.end].iter().collect();

    let (index, captures) = templates
        .iter()
        .enumerate()
        .filter(|(_, (template_kind, _))| *template_kind == kind)
        .find_map(|(i, (_, regex))| regex.captures(message).map(|c| (i, c)))
        .ok_or_else(|| format!("{kind} message '{message}' matches no template"))?;
    let has_span_group = templates[index]
        .1
        .capture_names()
        .any(|n| n == Some("span"));
    match captures.name("span") {
        Some(text) if text.as_str() != spanned => {
            return Err(format!(
                "message echoes '{}' but the span holds '{spanned}'",
                text.as_str()
            ))
        }
        None if has_span_group && span.start != span.end => {
            return Err(format!("end of input with a non-empty span {span}"))
        }
        _ => {}
    }
    if let Some(keyword) = captures.name("keyword") {
        if keyword.as_str() != spanned.to_ascii_lowercase() {
            return Err(format!(
                "keyword '{}' but the span holds '{spanned}'",
                keyword.as_str()
            ));
        }
    }
    if let Some(code) = captures.name("code") {
        let shown = u32::from_str_radix(code.as_str(), 16).unwrap();
        let actual = spanned.chars().next().map(u32::from);
        let quotable = (0x21..=0x7e).contains(&shown) && shown != 0x27;
        if actual != Some(shown) || spanned.chars().count() != 1 || quotable {
            return Err(format!("U+{} does not describe '{spanned}'", code.as_str()));
        }
    }

    let expected_suggestion =
        captures
            .name("month")
            .zip(captures.name("day"))
            .map(|(month, day)| {
                format!(
                    "until {} {} starting YYYY-MM-DD",
                    month.as_str(),
                    day.as_str()
                )
            });
    if suggestion.map(str::to_string) != expected_suggestion {
        return Err(format!(
            "suggestion {suggestion:?}, expected {expected_suggestion:?}"
        ));
    }

    let rich = error.display_rich();
    if rich.split('\n').count() != 3 || !rich.starts_with(&format!("error: {message}\n")) {
        return Err(format!("displayRich is not three lines: {rich:?}"));
    }
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
        .map(|((_, regex), _)| regex.as_str())
        .collect();
    assert!(
        unused.is_empty(),
        "templates no input produced: {unused:#?}"
    );
}
