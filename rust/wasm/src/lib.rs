use wasm_bindgen::prelude::*;

#[path = "../../hron-cli/src/timestamp.rs"]
mod timestamp;

fn timestamp_argument(name: &str, value: &JsValue) -> Result<jiff::Zoned, JsValue> {
    let Some(text) = value.as_string() else {
        return Err(js_sys::TypeError::new(&format!("{name} must be a string")).into());
    };
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
    /// Throws a TypeError when `now` is not a string, and a RangeError when it is not a valid timestamp.
    #[wasm_bindgen(js_name = "nextFrom")]
    pub fn next_from(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] now: JsValue,
    ) -> Result<Option<String>, JsValue> {
        let now = timestamp_argument("now", &now)?;
        let result = self.inner.next_from(&now).map_err(hron_error)?;
        Ok(result.map(|z| z.to_string()))
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
        let results = self.inner.next_n_from(&now, n).map_err(hron_error)?;
        Ok(results.iter().map(|z| z.to_string()).collect())
    }

    /// Compute the most recent occurrence strictly before `now`.
    /// Throws a TypeError when `now` is not a string, and a RangeError when it is not a valid timestamp.
    #[wasm_bindgen(js_name = "previousFrom")]
    pub fn previous_from(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] now: JsValue,
    ) -> Result<Option<String>, JsValue> {
        let now = timestamp_argument("now", &now)?;
        let result = self.inner.previous_from(&now).map_err(hron_error)?;
        Ok(result.map(|z| z.to_string()))
    }

    /// Check whether the minute containing `datetime` is an occurrence (seconds are ignored).
    /// Throws a TypeError when `datetime` is not a string, and a RangeError when it is not a valid timestamp.
    pub fn matches(
        &self,
        #[wasm_bindgen(unchecked_param_type = "string")] datetime: JsValue,
    ) -> Result<bool, JsValue> {
        let dt = timestamp_argument("datetime", &datetime)?;
        self.inner.matches(&dt).map_err(hron_error)
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
    pub fn validate(input: &str) -> bool {
        hron::Schedule::parse(input).is_ok()
    }

    /// Get the IANA timezone name, if specified, with the capitalization the timezone database uses.
    #[wasm_bindgen(getter)]
    pub fn timezone(&self) -> Option<String> {
        self.inner.timezone().map(|s| s.to_string())
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
        self.inner
            .occurrences(&from)
            .take(limit)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(hron_error)
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
        self.inner
            .between(&from, &to)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(hron_error)
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
