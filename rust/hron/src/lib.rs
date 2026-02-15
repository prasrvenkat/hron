//! hron — Human-readable cron.
//!
//! Human-readable schedule expressions that are a superset of what cron can express.
//!
//! # Examples
//!
//! ```
//! use hron::Schedule;
//!
//! let schedule: Schedule = "every weekday at 09:00".parse().unwrap();
//! println!("{}", schedule); // "every weekday at 09:00"
//! ```

pub mod ast;
pub mod cron;
pub mod display;
pub mod error;
pub mod eval;
pub mod lexer;
pub mod parser;

pub use ast::{Schedule, ScheduleExpr};
pub use error::ScheduleError;

use jiff::Zoned;
#[cfg(feature = "serde")]
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::str::FromStr;

// --- Schedule convenience methods ---

impl Schedule {
    /// Parse an hron expression string.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every weekday at 09:00").unwrap();
    /// assert_eq!(schedule.to_string(), "every weekday at 09:00");
    ///
    /// // With timezone modifier
    /// let schedule = Schedule::parse("every day at 12:00 in UTC").unwrap();
    /// assert_eq!(schedule.timezone(), Some("UTC"));
    /// ```
    pub fn parse(input: &str) -> Result<Self, ScheduleError> {
        parser::parse(input)
    }

    /// Compute the next occurrence after `now`.
    ///
    /// Returns `Ok(None)` when there are no future occurrences (e.g., past the
    /// `until` date). Returns `Err` on evaluation errors such as invalid
    /// timezone or date arithmetic overflow.
    ///
    /// **DST behavior:** When a scheduled time falls in a DST gap (e.g. 2:30 AM
    /// during spring-forward), the occurrence shifts to the next valid time as
    /// resolved by the `jiff` library. During fall-back, ambiguous times resolve
    /// to the first (pre-transition) occurrence.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let now: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    /// let next = schedule.next_from(&now).unwrap().unwrap();
    /// assert_eq!(next.to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// ```
    pub fn next_from(&self, now: &Zoned) -> Result<Option<Zoned>, ScheduleError> {
        eval::next_from(self, now)
    }

    /// Compute the next `n` occurrences after `now`.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let now: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    /// let next_3 = schedule.next_n_from(&now, 3).unwrap();
    /// assert_eq!(next_3.len(), 3);
    /// assert_eq!(next_3[0].to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// assert_eq!(next_3[2].to_string(), "2025-06-17T09:00:00+00:00[UTC]");
    /// ```
    pub fn next_n_from(&self, now: &Zoned, n: usize) -> Result<Vec<Zoned>, ScheduleError> {
        eval::next_n_from(self, now, n)
    }

    /// Check if a datetime matches this schedule.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    ///
    /// let matching: jiff::Zoned = "2025-06-15T09:00:00+00:00[UTC]".parse().unwrap();
    /// assert!(schedule.matches(&matching).unwrap());
    ///
    /// let non_matching: jiff::Zoned = "2025-06-15T10:00:00+00:00[UTC]".parse().unwrap();
    /// assert!(!schedule.matches(&non_matching).unwrap());
    /// ```
    pub fn matches(&self, datetime: &Zoned) -> Result<bool, ScheduleError> {
        eval::matches(self, datetime)
    }

    /// Set the anchor date for multi-week intervals.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// // Every 2 weeks on Monday, anchored to a specific start date
    /// let schedule = Schedule::parse("every 2 weeks on monday at 09:00 in UTC").unwrap()
    ///     .with_anchor(jiff::civil::date(2025, 1, 6));
    /// let now: jiff::Zoned = "2025-01-19T10:00:00+00:00[UTC]".parse().unwrap();
    /// let next = schedule.next_from(&now).unwrap().unwrap();
    /// assert_eq!(next.to_string(), "2025-01-20T09:00:00+00:00[UTC]");
    /// ```
    pub fn with_anchor(mut self, date: jiff::civil::Date) -> Self {
        self.anchor = Some(date);
        self
    }

    /// Check if an input string is a valid hron expression.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// assert!(Schedule::validate("every day at 09:00"));
    /// assert!(!Schedule::validate("not a valid expression"));
    /// ```
    pub fn validate(input: &str) -> bool {
        Self::parse(input).is_ok()
    }

    /// Convert a 5-field cron expression to a Schedule.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::from_cron("0 9 * * 1-5").unwrap();
    /// assert_eq!(schedule.to_string(), "every weekday at 09:00");
    /// ```
    pub fn from_cron(cron_expr: &str) -> Result<Self, ScheduleError> {
        cron::from_cron(cron_expr)
    }

    /// Convert this schedule to a 5-field cron expression.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00").unwrap();
    /// assert_eq!(schedule.to_cron().unwrap(), "0 9 * * *");
    ///
    /// // Schedules that exceed cron's capabilities return an error
    /// let schedule = Schedule::parse("every 2 weeks on monday at 09:00").unwrap();
    /// assert!(schedule.to_cron().is_err());
    /// ```
    pub fn to_cron(&self) -> Result<String, ScheduleError> {
        cron::to_cron(self)
    }

    /// Get the timezone for this schedule, if specified.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in America/New_York").unwrap();
    /// assert_eq!(schedule.timezone(), Some("America/New_York"));
    ///
    /// let schedule = Schedule::parse("every day at 09:00").unwrap();
    /// assert_eq!(schedule.timezone(), None);
    /// ```
    pub fn timezone(&self) -> Option<&str> {
        self.timezone.as_deref()
    }

    /// Returns a lazy iterator of occurrences starting after `from`.
    ///
    /// The iterator yields `Result<Zoned, ScheduleError>` values. It is unbounded
    /// for repeating schedules (will iterate forever unless limited), but respects
    /// the `until` clause if specified in the schedule.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let from: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    ///
    /// // Take first 5 occurrences
    /// let first_5: Vec<_> = schedule.occurrences(&from).take(5).collect::<Result<_, _>>().unwrap();
    /// assert_eq!(first_5.len(), 5);
    /// assert_eq!(first_5[0].to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// ```
    pub fn occurrences(&self, from: &Zoned) -> eval::Occurrences<'_> {
        eval::Occurrences::new(self, from.clone())
    }

    /// Returns a bounded iterator of occurrences in the range `(from, to]`.
    ///
    /// The iterator yields occurrences strictly after `from` and up to and including `to`.
    /// This is useful for querying all occurrences within a specific date range.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let from: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    /// let to: jiff::Zoned = "2025-06-18T10:00:00+00:00[UTC]".parse().unwrap();
    ///
    /// let occurrences: Vec<_> = schedule.between(&from, &to).collect::<Result<_, _>>().unwrap();
    /// assert_eq!(occurrences.len(), 4); // June 15, 16, 17, 18 at 09:00
    /// ```
    pub fn between(&self, from: &Zoned, to: &Zoned) -> eval::BoundedOccurrences<'_> {
        eval::between(self, from, to)
    }
}

impl FromStr for Schedule {
    type Err = ScheduleError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

/// Serialization produces a structured JSON object with fields like `kind`,
/// `interval`, `times`, `except`, `timezone`, etc. — designed for inspection,
/// logging, and debugging.
///
/// **Note:** Serialization and deserialization are intentionally asymmetric.
/// `Serialize` produces a structured JSON object while `Deserialize` expects
/// an hron expression string (e.g. `"every day at 09:00"`). This means
/// `serde_json::from_str(serde_json::to_string(&schedule))` will **not**
/// round-trip. This is by design: the structured JSON is for inspection,
/// while deserialization accepts the compact expression format used in
/// configuration files and APIs.
#[cfg(feature = "serde")]
impl Serialize for Schedule {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut map = serializer.serialize_map(None)?;

        match &self.expr {
            ScheduleExpr::IntervalRepeat {
                interval,
                unit,
                from,
                to,
                day_filter,
            } => {
                map.serialize_entry("kind", "every")?;
                map.serialize_entry(
                    "interval",
                    &serde_json::json!({
                        "value": interval,
                        "unit": match unit {
                            ast::IntervalUnit::Minutes => "minutes",
                            ast::IntervalUnit::Hours => "hours",
                        }
                    }),
                )?;
                map.serialize_entry("from", from)?;
                map.serialize_entry("to", to)?;
                if let Some(df) = day_filter {
                    map.serialize_entry("days", &day_filter_to_json(df))?;
                }
            }
            ScheduleExpr::DayRepeat {
                interval,
                days,
                times,
            } => {
                map.serialize_entry("kind", "every")?;
                if *interval > 1 {
                    map.serialize_entry(
                        "interval",
                        &serde_json::json!({
                            "value": interval,
                            "unit": "days"
                        }),
                    )?;
                }
                map.serialize_entry("days", &day_filter_to_json(days))?;
                map.serialize_entry("times", times)?;
            }
            ScheduleExpr::WeekRepeat {
                interval,
                days,
                times,
            } => {
                map.serialize_entry("kind", "every")?;
                map.serialize_entry(
                    "interval",
                    &serde_json::json!({
                        "value": interval,
                        "unit": "weeks"
                    }),
                )?;
                map.serialize_entry("days", days)?;
                map.serialize_entry("times", times)?;
            }
            ScheduleExpr::MonthRepeat {
                interval,
                target,
                times,
            } => {
                map.serialize_entry("kind", "every")?;
                map.serialize_entry("repeat", "monthly")?;
                if *interval > 1 {
                    map.serialize_entry(
                        "interval",
                        &serde_json::json!({
                            "value": interval,
                            "unit": "months"
                        }),
                    )?;
                }
                map.serialize_entry("target", target)?;
                map.serialize_entry("times", times)?;
            }
            ScheduleExpr::OrdinalRepeat {
                interval,
                ordinal,
                day,
                times,
            } => {
                map.serialize_entry("kind", "every")?;
                if *interval > 1 {
                    map.serialize_entry(
                        "interval",
                        &serde_json::json!({
                            "value": interval,
                            "unit": "months"
                        }),
                    )?;
                }
                map.serialize_entry("ordinal", ordinal)?;
                map.serialize_entry("day", day)?;
                map.serialize_entry("times", times)?;
            }
            ScheduleExpr::SingleDate { date, times } => {
                map.serialize_entry("kind", "on")?;
                match date {
                    ast::DateSpec::Iso(d) => map.serialize_entry("date", d)?,
                    ast::DateSpec::Named { month, day } => {
                        map.serialize_entry("date", &format!("{} {}", month.as_str(), day))?;
                    }
                }
                map.serialize_entry("times", times)?;
            }
            ScheduleExpr::YearRepeat {
                interval,
                target,
                times,
            } => {
                map.serialize_entry("kind", "every")?;
                map.serialize_entry("repeat", "yearly")?;
                if *interval > 1 {
                    map.serialize_entry(
                        "interval",
                        &serde_json::json!({
                            "value": interval,
                            "unit": "years"
                        }),
                    )?;
                }
                map.serialize_entry("target", target)?;
                map.serialize_entry("times", times)?;
            }
        }

        // Shared modifiers — always present for a consistent JSON shape
        map.serialize_entry("except", &self.except)?;
        map.serialize_entry("until", &self.until)?;
        map.serialize_entry("starting", &self.anchor.as_ref().map(|a| a.to_string()))?;
        map.serialize_entry("during", &self.during)?;
        map.serialize_entry("timezone", &self.timezone)?;

        map.end()
    }
}

#[cfg(feature = "serde")]
fn day_filter_to_json(filter: &ast::DayFilter) -> serde_json::Value {
    match filter {
        ast::DayFilter::Every => serde_json::json!([
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday",
            "sunday"
        ]),
        ast::DayFilter::Weekday => {
            serde_json::json!(["monday", "tuesday", "wednesday", "thursday", "friday"])
        }
        ast::DayFilter::Weekend => serde_json::json!(["saturday", "sunday"]),
        ast::DayFilter::Days(days) => {
            serde_json::json!(days.iter().map(|d| d.as_str()).collect::<Vec<_>>())
        }
    }
}

/// Deserialization expects an hron expression string (e.g. `"every day at 09:00"`),
/// **not** the structured JSON produced by `Serialize`. See the note on
/// [`Serialize`](#impl-Serialize-for-Schedule) for details on this intentional
/// asymmetry.
#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Schedule {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Schedule::parse(&s).map_err(serde::de::Error::custom)
    }
}
