use hron::ast::{
    DateSpec, DayFilter, DayOfMonthSpec, Exception, MonthName, MonthTarget, NearestDirection,
    TimeOfDay, UntilSpec, Weekday, YearTarget,
};
use hron::{ErrorKind, ScheduleExpr};
use wasm_bindgen::prelude::*;

#[path = "../../hron-cli/src/timestamp.rs"]
mod timestamp;

#[wasm_bindgen(typescript_custom_section)]
const TYPES: &'static str = r#"
export type Weekday = "monday" | "tuesday" | "wednesday" | "thursday" | "friday" | "saturday" | "sunday";
export type MonthName = "jan" | "feb" | "mar" | "apr" | "may" | "jun" | "jul" | "aug" | "sep" | "oct" | "nov" | "dec";
export type IntervalUnit = "min" | "hours";
export type OrdinalPosition = "first" | "second" | "third" | "fourth" | "fifth" | "last";
export type NearestDirection = "next" | "previous";

export interface TimeOfDay {
  readonly hour: number;
  readonly minute: number;
}

export type DayFilter =
  | { readonly type: "every" }
  | { readonly type: "weekday" }
  | { readonly type: "weekend" }
  | { readonly type: "days"; readonly days: readonly Weekday[] };

export type DayOfMonthSpec =
  | { readonly type: "single"; readonly day: number }
  | { readonly type: "range"; readonly start: number; readonly end: number };

export type MonthTarget =
  | { readonly type: "days"; readonly specs: readonly DayOfMonthSpec[] }
  | { readonly type: "lastDay" }
  | { readonly type: "lastWeekday" }
  | { readonly type: "nearestWeekday"; readonly day: number; readonly direction: NearestDirection | null }
  | { readonly type: "ordinalWeekday"; readonly ordinal: OrdinalPosition; readonly weekday: Weekday };

export type YearTarget =
  | { readonly type: "date"; readonly month: MonthName; readonly day: number }
  | { readonly type: "ordinalWeekday"; readonly ordinal: OrdinalPosition; readonly weekday: Weekday; readonly month: MonthName }
  | { readonly type: "dayOfMonth"; readonly day: number; readonly month: MonthName }
  | { readonly type: "lastWeekday"; readonly month: MonthName };

export type DateSpec =
  | { readonly type: "named"; readonly month: MonthName; readonly day: number }
  | { readonly type: "iso"; readonly date: string };

export type Exception = DateSpec;

export type UntilSpec = DateSpec;

export type ScheduleExpr =
  | { readonly type: "intervalRepeat"; readonly interval: number; readonly unit: IntervalUnit; readonly from: TimeOfDay; readonly to: TimeOfDay; readonly dayFilter: DayFilter | null }
  | { readonly type: "dayRepeat"; readonly interval: number; readonly days: DayFilter; readonly times: readonly TimeOfDay[] }
  | { readonly type: "weekRepeat"; readonly interval: number; readonly days: readonly Weekday[]; readonly times: readonly TimeOfDay[] }
  | { readonly type: "monthRepeat"; readonly interval: number; readonly target: MonthTarget; readonly times: readonly TimeOfDay[] }
  | { readonly type: "singleDate"; readonly date: DateSpec; readonly times: readonly TimeOfDay[] }
  | { readonly type: "yearRepeat"; readonly interval: number; readonly target: YearTarget; readonly times: readonly TimeOfDay[] };

export type HronErrorKind = "lex" | "parse" | "eval" | "cron";

/** `[start, end)` in code points, not UTF-16 units. */
export interface Span {
  readonly start: number;
  readonly end: number;
}

/** What hron throws; `span` and `input` are present for `lex` and `parse` errors. */
export interface HronError extends Error {
  readonly kind: HronErrorKind;
  readonly span?: Span;
  readonly input?: string;
  readonly suggestion?: string;
  displayRich(): string;
}
"#;

fn string_argument(name: &str, value: &JsValue) -> Result<String, JsValue> {
    value
        .as_string()
        .ok_or_else(|| js_sys::TypeError::new(&format!("{name} must be a string")).into())
}

fn timestamp_argument(name: &str, value: &JsValue) -> Result<jiff::Zoned, JsValue> {
    let text = string_argument(name, value)?;
    timestamp::parse_timestamp(&text).map_err(|message| js_sys::RangeError::new(&message).into())
}

/// A count of zero or less asks for nothing, and one beyond `usize` only caps
/// what is returned (spec/README.md, "Timestamps and counts"); `as` saturates.
fn count_argument(name: &str, value: &JsValue) -> Result<usize, JsValue> {
    let Some(count) = value.as_f64() else {
        return Err(js_sys::TypeError::new(&format!("{name} must be a number")).into());
    };
    if !js_sys::Number::is_integer(value) {
        return Err(
            js_sys::RangeError::new(&format!("{name} must be an integer, not {count}")).into(),
        );
    }
    Ok(count.max(0.0) as usize)
}

fn set(target: &JsValue, key: &str, value: impl Into<JsValue>) {
    js_sys::Reflect::set(target, &key.into(), &value.into())
        .expect("a new object accepts properties");
}

fn hron_error(error: hron::ScheduleError) -> JsValue {
    let js_error: JsValue = js_sys::Error::new(error.message()).into();
    let kind = match error.kind() {
        ErrorKind::Lex => "lex",
        ErrorKind::Parse => "parse",
        ErrorKind::Eval => "eval",
        ErrorKind::Cron => "cron",
    };
    set(&js_error, "kind", kind);
    if let (Some(span), Some(input)) = (error.span(), error.input()) {
        let span_object: JsValue = js_sys::Object::new().into();
        set(&span_object, "start", span.start);
        set(&span_object, "end", span.end);
        set(&js_error, "span", span_object);
        set(&js_error, "input", input);
        set(&js_error, "suggestion", error.suggestion());
    }
    // String.prototype.toString bound to the rendered text is a method that returns
    // it, without eval (blocked in Workers) or a Rust closure for JS to free.
    let string_prototype = js_sys::Object::get_prototype_of(&"".into());
    let to_string: js_sys::Function = js_sys::Reflect::get(&string_prototype, &"toString".into())
        .expect("String.prototype has toString")
        .into();
    set(
        &js_error,
        "displayRich",
        to_string.bind0(&error.display_rich().into()),
    );
    js_error
}

// The shapes hron-ts gives its getters (ts/src/ast.ts), with its key order,
// frozen at every level as hron-ts freezes them.
// hron's enums are non_exhaustive, so each match needs an arm for a variant
// added later.
const NEW_VARIANT: &str = "hron-wasm converts every variant of the hron it is built with";

fn object<const N: usize>(entries: [(&str, JsValue); N]) -> JsValue {
    let object = js_sys::Object::new();
    for (key, value) in entries {
        set(&object, key, value);
    }
    js_sys::Object::freeze(&object).into()
}

fn array<T>(items: &[T], each: impl Fn(&T) -> JsValue) -> JsValue {
    let array: js_sys::Array = items.iter().map(each).collect();
    js_sys::Object::freeze(&array).into()
}

fn tagged(tag: &str) -> (&'static str, JsValue) {
    ("type", tag.into())
}

fn time_js(time: &TimeOfDay) -> JsValue {
    object([("hour", time.hour.into()), ("minute", time.minute.into())])
}

fn times_js(times: &[TimeOfDay]) -> JsValue {
    array(times, time_js)
}

fn weekdays_js(days: &[Weekday]) -> JsValue {
    array(days, |day| day.as_str().into())
}

fn named_js(month: MonthName, day: u8) -> JsValue {
    object([
        tagged("named"),
        ("month", month.as_str().into()),
        ("day", day.into()),
    ])
}

fn iso_js(date: &str) -> JsValue {
    object([tagged("iso"), ("date", date.into())])
}

fn day_filter_js(filter: &DayFilter) -> JsValue {
    match filter {
        DayFilter::Every => object([tagged("every")]),
        DayFilter::Weekday => object([tagged("weekday")]),
        DayFilter::Weekend => object([tagged("weekend")]),
        DayFilter::Days(days) => object([tagged("days"), ("days", weekdays_js(days))]),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn day_spec_js(spec: &DayOfMonthSpec) -> JsValue {
    match spec {
        DayOfMonthSpec::Single(day) => object([tagged("single"), ("day", (*day).into())]),
        DayOfMonthSpec::Range(start, end) => object([
            tagged("range"),
            ("start", (*start).into()),
            ("end", (*end).into()),
        ]),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn direction_js(direction: Option<NearestDirection>) -> JsValue {
    match direction {
        None => JsValue::NULL,
        Some(NearestDirection::Next) => "next".into(),
        Some(NearestDirection::Previous) => "previous".into(),
        Some(_) => unreachable!("{NEW_VARIANT}"),
    }
}

fn month_target_js(target: &MonthTarget) -> JsValue {
    match target {
        MonthTarget::Days(specs) => object([tagged("days"), ("specs", array(specs, day_spec_js))]),
        MonthTarget::LastDay => object([tagged("lastDay")]),
        MonthTarget::LastWeekday => object([tagged("lastWeekday")]),
        MonthTarget::NearestWeekday { day, direction } => object([
            tagged("nearestWeekday"),
            ("day", (*day).into()),
            ("direction", direction_js(*direction)),
        ]),
        MonthTarget::OrdinalWeekday { ordinal, weekday } => object([
            tagged("ordinalWeekday"),
            ("ordinal", ordinal.as_str().into()),
            ("weekday", weekday.as_str().into()),
        ]),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn year_target_js(target: &YearTarget) -> JsValue {
    match target {
        YearTarget::Date { month, day } => object([
            tagged("date"),
            ("month", month.as_str().into()),
            ("day", (*day).into()),
        ]),
        YearTarget::OrdinalWeekday {
            ordinal,
            weekday,
            month,
        } => object([
            tagged("ordinalWeekday"),
            ("ordinal", ordinal.as_str().into()),
            ("weekday", weekday.as_str().into()),
            ("month", month.as_str().into()),
        ]),
        YearTarget::DayOfMonth { day, month } => object([
            tagged("dayOfMonth"),
            ("day", (*day).into()),
            ("month", month.as_str().into()),
        ]),
        YearTarget::LastWeekday { month } => {
            object([tagged("lastWeekday"), ("month", month.as_str().into())])
        }
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn date_js(date: &DateSpec) -> JsValue {
    match date {
        DateSpec::Named { month, day } => named_js(*month, *day),
        DateSpec::Iso(date) => iso_js(date),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn expression_js(expression: &ScheduleExpr) -> JsValue {
    match expression {
        ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            day_filter,
        } => object([
            tagged("intervalRepeat"),
            ("interval", (*interval).into()),
            ("unit", unit.as_str().into()),
            ("from", time_js(from)),
            ("to", time_js(to)),
            (
                "dayFilter",
                day_filter.as_ref().map_or(JsValue::NULL, day_filter_js),
            ),
        ]),
        ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        } => object([
            tagged("dayRepeat"),
            ("interval", (*interval).into()),
            ("days", day_filter_js(days)),
            ("times", times_js(times)),
        ]),
        ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        } => object([
            tagged("weekRepeat"),
            ("interval", (*interval).into()),
            ("days", weekdays_js(days)),
            ("times", times_js(times)),
        ]),
        ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        } => object([
            tagged("monthRepeat"),
            ("interval", (*interval).into()),
            ("target", month_target_js(target)),
            ("times", times_js(times)),
        ]),
        ScheduleExpr::SingleDate { date, times } => object([
            tagged("singleDate"),
            ("date", date_js(date)),
            ("times", times_js(times)),
        ]),
        ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        } => object([
            tagged("yearRepeat"),
            ("interval", (*interval).into()),
            ("target", year_target_js(target)),
            ("times", times_js(times)),
        ]),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn exception_js(exception: &Exception) -> JsValue {
    match exception {
        Exception::Named { month, day } => named_js(*month, *day),
        Exception::Iso(date) => iso_js(date),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

fn until_js(until: &UntilSpec) -> JsValue {
    match until {
        UntilSpec::Named { month, day } => named_js(*month, *day),
        UntilSpec::Iso(date) => iso_js(date),
        _ => unreachable!("{NEW_VARIANT}"),
    }
}

/// A parsed hron schedule, usable from JavaScript.
#[wasm_bindgen]
pub struct Schedule {
    inner: hron::Schedule,
}

#[wasm_bindgen]
impl Schedule {
    /// Parse an hron expression string.
    /// Throws an Error whose `kind` is `lex` or `parse` on an invalid expression,
    /// and a TypeError when `input` is not a string.
    #[wasm_bindgen]
    pub fn parse(
        #[wasm_bindgen(unchecked_param_type = "string")] input: JsValue,
    ) -> Result<Schedule, JsValue> {
        let input = string_argument("input", &input)?;
        let inner = hron::Schedule::parse(&input).map_err(hron_error)?;
        Ok(Schedule { inner })
    }

    /// Compute the next occurrence strictly after `now`.
    /// Throws a TypeError when `now` is not a string, and a RangeError when it is not a valid timestamp.
    #[wasm_bindgen(js_name = "nextFrom", unchecked_return_type = "string | null")]
    pub fn next_from(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] now: JsValue,
    ) -> Result<JsValue, JsValue> {
        let now = timestamp_argument("now", &now)?;
        Ok(match self.inner.next_from(&now) {
            Some(z) => JsValue::from_str(&z.to_string()),
            None => JsValue::NULL,
        })
    }

    /// Compute up to `n` occurrences strictly after `now`, none when `n <= 0`.
    /// Throws a TypeError for an argument of the wrong type, and a RangeError for a
    /// timestamp that is not valid, or an `n` that is not an integer.
    #[wasm_bindgen(js_name = "nextNFrom")]
    pub fn next_n_from(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] now: JsValue,
        #[wasm_bindgen(unchecked_param_type = "number")] n: JsValue,
    ) -> Result<Vec<String>, JsValue> {
        let now = timestamp_argument("now", &now)?;
        let n = count_argument("n", &n)?;
        let results = self.inner.next_n_from(&now, n);
        Ok(results.iter().map(|z| z.to_string()).collect())
    }

    /// Compute the most recent occurrence strictly before `now`.
    /// Throws a TypeError when `now` is not a string, and a RangeError when it is not a valid timestamp.
    #[wasm_bindgen(js_name = "previousFrom", unchecked_return_type = "string | null")]
    pub fn previous_from(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] now: JsValue,
    ) -> Result<JsValue, JsValue> {
        let now = timestamp_argument("now", &now)?;
        Ok(match self.inner.previous_from(&now) {
            Some(z) => JsValue::from_str(&z.to_string()),
            None => JsValue::NULL,
        })
    }

    /// Check whether the minute containing `datetime` is an occurrence (seconds are ignored).
    /// Throws a TypeError when `datetime` is not a string, and a RangeError when it is not a valid timestamp.
    pub fn matches(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] datetime: JsValue,
    ) -> Result<bool, JsValue> {
        let dt = timestamp_argument("datetime", &datetime)?;
        Ok(self.inner.matches(&dt))
    }

    /// Get the structured JSON representation as a plain object, which `JSON.stringify` uses.
    #[wasm_bindgen(js_name = "toJSON")]
    pub fn to_json(&self) -> JsValue {
        let json = serde_json::to_string(&self.inner).expect("a schedule serializes");
        js_sys::JSON::parse(&json).expect("serde_json writes valid JSON")
    }

    /// Convert this schedule to a cron expression that fires at the same times.
    /// Throws an Error whose `kind` is `cron` when no cron does.
    #[wasm_bindgen(js_name = "toCron")]
    pub fn to_cron(&self) -> Result<String, JsValue> {
        self.inner.to_cron().map_err(hron_error)
    }

    #[wasm_bindgen(js_name = "toString")]
    pub fn display(&self) -> String {
        self.inner.to_string()
    }

    /// False, rather than throwing, for anything `parse` rejects.
    /// Throws a TypeError when `input` is not a string.
    pub fn validate(
        #[wasm_bindgen(unchecked_param_type = "string")] input: JsValue,
    ) -> Result<bool, JsValue> {
        let input = string_argument("input", &input)?;
        Ok(hron::Schedule::parse(&input).is_ok())
    }

    /// True when `other` is a schedule with equal parts; false for anything else.
    pub fn equals(&self, #[wasm_bindgen(unchecked_param_type = "unknown")] other: JsValue) -> bool {
        // wasm-bindgen borrows a schedule only through a `&Schedule` parameter,
        // which throws for anything else, so this finds the class by the
        // prototype of a schedule made here, and reads `other` through its text,
        // which parses back to its parts (spec/README.md, "Equality").
        let made_here = JsValue::from(Schedule {
            inner: self.inner.clone(),
        });
        let prototype = js_sys::Object::get_prototype_of(&made_here);
        if js_sys::Reflect::get_prototype_of(&other).ok() != Some(prototype.clone()) {
            return false;
        }
        let to_string: js_sys::Function = js_sys::Reflect::get(&prototype, &"toString".into())
            .expect("Schedule.prototype has toString")
            .into();
        // A schedule whose memory was freed with free() throws here.
        let Some(text) = to_string
            .call0(&other)
            .ok()
            .and_then(|text| text.as_string())
        else {
            return false;
        };
        hron::Schedule::parse(&text).is_ok_and(|parts| parts == self.inner)
    }

    /// The IANA timezone name with the capitalization the timezone database uses, or null.
    #[wasm_bindgen(getter, unchecked_return_type = "string | null")]
    pub fn timezone(&self) -> JsValue {
        self.inner.timezone().map_or(JsValue::NULL, JsValue::from)
    }

    /// A plain object frozen at every level, shaped as hron-ts's `expression`.
    #[wasm_bindgen(getter, unchecked_return_type = "ScheduleExpr")]
    pub fn expression(&self) -> JsValue {
        expression_js(self.inner.expression())
    }

    /// Empty without an `except` clause.
    #[wasm_bindgen(getter, unchecked_return_type = "Exception[]")]
    pub fn except(&self) -> JsValue {
        array(self.inner.except(), exception_js)
    }

    #[wasm_bindgen(getter, unchecked_return_type = "UntilSpec | null")]
    pub fn until(&self) -> JsValue {
        self.inner.until().map_or(JsValue::NULL, until_js)
    }

    /// The starting date as YYYY-MM-DD, or null.
    #[wasm_bindgen(getter, unchecked_return_type = "string | null")]
    pub fn starting(&self) -> JsValue {
        self.inner
            .starting()
            .map_or(JsValue::NULL, |date| JsValue::from(date.to_string()))
    }

    /// Empty without a `during` clause.
    #[wasm_bindgen(getter, unchecked_return_type = "MonthName[]")]
    pub fn during(&self) -> JsValue {
        array(self.inner.during(), |month| month.as_str().into())
    }

    /// Returns up to `limit` occurrences strictly after `from`, none when `limit <= 0`.
    /// Throws a TypeError for an argument of the wrong type, and a RangeError for a
    /// timestamp that is not valid, or a `limit` that is not an integer.
    pub fn occurrences(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] from: JsValue,
        #[wasm_bindgen(unchecked_param_type = "number")] limit: JsValue,
    ) -> Result<Vec<String>, JsValue> {
        let from = timestamp_argument("from", &from)?;
        let limit = count_argument("limit", &limit)?;
        Ok(self
            .inner
            .occurrences(&from)
            .take(limit)
            .map(|z| z.to_string())
            .collect())
    }

    /// Returns occurrences in the range (from, to], where from is exclusive and to is inclusive.
    /// Throws a TypeError when `from` or `to` is not a string, and a RangeError when one is not a valid timestamp.
    pub fn between(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] from: JsValue,
        #[wasm_bindgen(unchecked_param_type = "string")] to: JsValue,
    ) -> Result<Vec<String>, JsValue> {
        let from = timestamp_argument("from", &from)?;
        let to = timestamp_argument("to", &to)?;
        Ok(self
            .inner
            .between(&from, &to)
            .map(|z| z.to_string())
            .collect())
    }
}

/// Explain a cron expression in human-readable form: the same as
/// `fromCron(cron).toString()`, with the same errors.
#[wasm_bindgen(js_name = "explainCron")]
pub fn explain_cron(
    #[wasm_bindgen(js_name = "cronExpr", unchecked_param_type = "string")] cron_expr: JsValue,
) -> Result<String, JsValue> {
    let cron_expr = string_argument("cronExpr", &cron_expr)?;
    hron::Schedule::explain_cron(&cron_expr).map_err(hron_error)
}

/// Parse a cron expression and return an hron Schedule that fires at the same times.
/// Throws an Error whose `kind` is `cron` on invalid cron or cron that hron cannot express
/// exactly, and a TypeError when `cronExpr` is not a string.
#[wasm_bindgen(js_name = "fromCron")]
pub fn from_cron(
    #[wasm_bindgen(js_name = "cronExpr", unchecked_param_type = "string")] cron_expr: JsValue,
) -> Result<Schedule, JsValue> {
    let cron_expr = string_argument("cronExpr", &cron_expr)?;
    let inner = hron::Schedule::from_cron(&cron_expr).map_err(hron_error)?;
    Ok(Schedule { inner })
}
