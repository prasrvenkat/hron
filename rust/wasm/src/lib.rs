use wasm_bindgen::prelude::*;

/// A parsed hron schedule, usable from JavaScript.
#[wasm_bindgen]
pub struct Schedule {
    inner: hron::Schedule,
}

#[wasm_bindgen]
impl Schedule {
    /// Parse an hron expression string.
    #[wasm_bindgen]
    pub fn parse(input: &str) -> Result<Schedule, JsError> {
        let inner = hron::Schedule::parse(input).map_err(|e| JsError::new(&e.to_string()))?;
        Ok(Schedule { inner })
    }

    /// Compute the next occurrence after `now`.
    #[wasm_bindgen(js_name = "nextFrom")]
    pub fn next_from(&self, now: &str) -> Result<Option<String>, JsError> {
        let now: jiff::Zoned = now
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        let result = self
            .inner
            .next_from(&now)
            .map_err(|e| JsError::new(&e.to_string()))?;
        Ok(result.map(|z| z.to_string()))
    }

    /// Compute the next `n` occurrences after `now`.
    #[wasm_bindgen(js_name = "nextNFrom")]
    pub fn next_n_from(&self, now: &str, n: u32) -> Result<JsValue, JsError> {
        let now: jiff::Zoned = now
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        let results = self
            .inner
            .next_n_from(&now, n as usize)
            .map_err(|e| JsError::new(&e.to_string()))?;
        let strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
        serde_wasm_bindgen::to_value(&strings).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Check if a datetime matches this schedule.
    pub fn matches(&self, datetime: &str) -> Result<bool, JsError> {
        let dt: jiff::Zoned = datetime
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        self.inner
            .matches(&dt)
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Get the structured JSON representation.
    #[wasm_bindgen(js_name = "toJSON")]
    pub fn to_json(&self) -> Result<JsValue, JsError> {
        serde_wasm_bindgen::to_value(&self.inner).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Convert this schedule to a cron expression (if possible).
    #[wasm_bindgen(js_name = "toCron")]
    pub fn to_cron(&self) -> Result<String, JsError> {
        self.inner
            .to_cron()
            .map_err(|e| JsError::new(&e.to_string()))
    }

    /// Get the display string.
    #[wasm_bindgen(js_name = "toString")]
    pub fn display(&self) -> String {
        self.inner.to_string()
    }

    /// Validate an expression (returns true if valid).
    pub fn validate(input: &str) -> bool {
        hron::Schedule::parse(input).is_ok()
    }

    /// Get the timezone, if specified.
    #[wasm_bindgen(getter)]
    pub fn timezone(&self) -> Option<String> {
        self.inner.timezone().map(|s| s.to_string())
    }

    /// Returns occurrences starting after `from`, limited to `limit` results.
    /// Returns an array of datetime strings.
    pub fn occurrences(&self, from: &str, limit: u32) -> Result<JsValue, JsError> {
        let from: jiff::Zoned = from
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        let results: Vec<String> = self
            .inner
            .occurrences(&from)
            .take(limit as usize)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(|e| JsError::new(&e.to_string()))?;
        serde_wasm_bindgen::to_value(&results).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Returns occurrences in the range (from, to], where from is exclusive and to is inclusive.
    /// Returns an array of datetime strings.
    pub fn between(&self, from: &str, to: &str) -> Result<JsValue, JsError> {
        let from: jiff::Zoned = from
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        let to: jiff::Zoned = to
            .parse()
            .map_err(|e: jiff::Error| JsError::new(&format!("{e}")))?;
        let results: Vec<String> = self
            .inner
            .between(&from, &to)
            .map(|r| r.map(|z| z.to_string()))
            .collect::<Result<_, _>>()
            .map_err(|e| JsError::new(&e.to_string()))?;
        serde_wasm_bindgen::to_value(&results).map_err(|e| JsError::new(&e.to_string()))
    }
}

/// Parse a cron expression and return an hron Schedule.
#[wasm_bindgen(js_name = "fromCron")]
pub fn from_cron(cron_expr: &str) -> Result<Schedule, JsError> {
    let inner = hron::Schedule::from_cron(cron_expr).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(Schedule { inner })
}
