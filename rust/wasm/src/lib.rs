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

    /// Get the next occurrence as an ISO string.
    /// Uses UTC as the default timezone in WASM.
    pub fn next(&self) -> Result<Option<String>, JsError> {
        let tz = jiff::tz::TimeZone::UTC;
        let now = jiff::Zoned::now().with_time_zone(tz);
        Ok(self.inner.next_from(&now).map(|z| z.to_string()))
    }

    /// Get the next N occurrences as an array of ISO strings.
    #[wasm_bindgen(js_name = "nextN")]
    pub fn next_n(&self, n: u32) -> Result<JsValue, JsError> {
        let tz = jiff::tz::TimeZone::UTC;
        let now = jiff::Zoned::now().with_time_zone(tz);
        let results = self.inner.next_n_from(&now, n as usize);
        let strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
        serde_wasm_bindgen::to_value(&strings).map_err(|e| JsError::new(&e.to_string()))
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
}

/// Parse a cron expression and return an hron Schedule.
#[wasm_bindgen(js_name = "fromCron")]
pub fn from_cron(cron_expr: &str) -> Result<Schedule, JsError> {
    let inner = hron::Schedule::from_cron(cron_expr).map_err(|e| JsError::new(&e.to_string()))?;
    Ok(Schedule { inner })
}
