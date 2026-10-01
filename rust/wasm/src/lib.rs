use wasm_bindgen::prelude::*;

/// jiff rejects an instant beyond its own range, which extends past the
/// supported range on both sides. A timestamp with a numeric offset and a known
/// zone whose instant is beyond jiff's range becomes jiff's nearest extreme, so
/// every method returns nothing for it instead of throwing (spec/README.md,
/// "Supported range"). Any other input that jiff rejects keeps jiff's error.
fn parse_zoned(s: &str) -> Result<jiff::Zoned, JsError> {
    let error = match s.parse::<jiff::Zoned>() {
        Ok(zoned) => return Ok(zoned),
        Err(e) => JsError::new(&e.to_string()),
    };
    let Ok(pieces) = jiff::fmt::temporal::Pieces::parse(s) else {
        return Err(error);
    };
    let (Some(offset), Ok(Some(_))) = (pieces.to_numeric_offset(), pieces.to_time_zone()) else {
        return Err(error);
    };
    let time = pieces.time().unwrap_or(jiff::civil::Time::midnight());
    let Ok(days) = jiff::civil::date(1970, 1, 1).until(pieces.date()) else {
        return Err(error);
    };
    let seconds = i128::from(days.get_days()) * 86_400
        + i128::from(time.hour()) * 3_600
        + i128::from(time.minute()) * 60
        + i128::from(time.second())
        - i128::from(offset.seconds());
    let extreme = if seconds < i128::from(jiff::Timestamp::MIN.as_second()) {
        jiff::Timestamp::MIN
    } else if seconds > i128::from(jiff::Timestamp::MAX.as_second()) {
        jiff::Timestamp::MAX
    } else {
        return Err(error);
    };
    Ok(extreme.to_zoned(jiff::tz::TimeZone::UTC))
}

fn set(target: &JsValue, key: &str, value: impl Into<JsValue>) {
    js_sys::Reflect::set(target, &key.into(), &value.into())
        .expect("a new object accepts properties");
}

fn hron_error(error: hron::ScheduleError) -> JsValue {
    let js_error: JsValue = js_sys::Error::new(&error.to_string()).into();
    let kind = match &error {
        hron::ScheduleError::Lex { .. } => "lex",
        hron::ScheduleError::Parse { .. } => "parse",
        hron::ScheduleError::Eval { .. } => "eval",
        hron::ScheduleError::Cron { .. } => "cron",
        _ => "unknown",
    };
    set(&js_error, "kind", kind);
    if let hron::ScheduleError::Lex { span, input, .. }
    | hron::ScheduleError::Parse { span, input, .. } = &error
    {
        let span_object: JsValue = js_sys::Object::new().into();
        set(&span_object, "start", span.start);
        set(&span_object, "end", span.end);
        set(&js_error, "span", span_object);
        set(&js_error, "input", input.as_str());
        let suggestion = match &error {
            hron::ScheduleError::Parse { suggestion, .. } => suggestion.as_deref(),
            _ => None,
        };
        set(&js_error, "suggestion", suggestion);
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

/// A parsed hron schedule, usable from JavaScript.
#[wasm_bindgen]
pub struct Schedule {
    inner: hron::Schedule,
}

#[wasm_bindgen]
impl Schedule {
    /// Parse an hron expression string.
    /// Throws an Error whose `kind` is `lex` or `parse` on an invalid expression.
    #[wasm_bindgen]
    pub fn parse(input: &str) -> Result<Schedule, JsValue> {
        let inner = hron::Schedule::parse(input).map_err(hron_error)?;
        Ok(Schedule { inner })
    }

    /// Compute the next occurrence strictly after `now`.
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    #[wasm_bindgen(js_name = "nextFrom")]
    pub fn next_from(&self, now: &str) -> Result<Option<String>, JsValue> {
        let now = parse_zoned(now)?;
        let result = self.inner.next_from(&now).map_err(hron_error)?;
        Ok(result.map(|z| z.to_string()))
    }

    /// Compute the next `n` occurrences strictly after `now`.
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    #[wasm_bindgen(js_name = "nextNFrom")]
    pub fn next_n_from(&self, now: &str, n: u32) -> Result<JsValue, JsValue> {
        let now = parse_zoned(now)?;
        let results = self
            .inner
            .next_n_from(&now, n as usize)
            .map_err(hron_error)?;
        let strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
        serde_wasm_bindgen::to_value(&strings).map_err(|e| JsError::new(&e.to_string()).into())
    }

    /// Compute the most recent occurrence strictly before `now`.
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    #[wasm_bindgen(js_name = "previousFrom")]
    pub fn previous_from(&self, now: &str) -> Result<Option<String>, JsValue> {
        let now = parse_zoned(now)?;
        let result = self.inner.previous_from(&now).map_err(hron_error)?;
        Ok(result.map(|z| z.to_string()))
    }

    /// Check whether the minute containing `datetime` is an occurrence (seconds are ignored).
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    pub fn matches(&self, datetime: &str) -> Result<bool, JsValue> {
        let dt = parse_zoned(datetime)?;
        self.inner.matches(&dt).map_err(hron_error)
    }

    /// Get the structured JSON representation.
    #[wasm_bindgen(js_name = "toJSON")]
    pub fn to_json(&self) -> Result<JsValue, JsError> {
        serde_wasm_bindgen::to_value(&self.inner).map_err(|e| JsError::new(&e.to_string()))
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
    pub fn validate(input: &str) -> bool {
        hron::Schedule::parse(input).is_ok()
    }

    /// Get the IANA timezone name, if specified, with the capitalization the timezone database uses.
    #[wasm_bindgen(getter)]
    pub fn timezone(&self) -> Option<String> {
        self.inner.timezone().map(|s| s.to_string())
    }

    /// Returns occurrences strictly after `from`, limited to `limit` results.
    /// Returns an array of datetime strings.
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    pub fn occurrences(&self, from: &str, limit: u32) -> Result<JsValue, JsValue> {
        let from = parse_zoned(from)?;
        let results: Vec<String> = self
            .inner
            .occurrences(&from)
            .take(limit as usize)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(hron_error)?;
        serde_wasm_bindgen::to_value(&results).map_err(|e| JsError::new(&e.to_string()).into())
    }

    /// Returns occurrences in the range (from, to], where from is exclusive and to is inclusive.
    /// Returns an array of datetime strings.
    /// Throws a plain Error, with no `kind`, on a datetime it cannot parse.
    pub fn between(&self, from: &str, to: &str) -> Result<JsValue, JsValue> {
        let from = parse_zoned(from)?;
        let to = parse_zoned(to)?;
        let results: Vec<String> = self
            .inner
            .between(&from, &to)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(hron_error)?;
        serde_wasm_bindgen::to_value(&results).map_err(|e| JsError::new(&e.to_string()).into())
    }
}

/// Explain a cron expression in human-readable form: the same as
/// `fromCron(cron).toString()`, with the same errors.
#[wasm_bindgen(js_name = "explainCron")]
pub fn explain_cron(cron_expr: &str) -> Result<String, JsValue> {
    hron::Schedule::explain_cron(cron_expr).map_err(hron_error)
}

/// Parse a cron expression and return an hron Schedule that fires at the same times.
/// Throws an Error whose `kind` is `cron` on invalid cron or cron that hron cannot express exactly.
#[wasm_bindgen(js_name = "fromCron")]
pub fn from_cron(cron_expr: &str) -> Result<Schedule, JsValue> {
    let inner = hron::Schedule::from_cron(cron_expr).map_err(hron_error)?;
    Ok(Schedule { inner })
}
