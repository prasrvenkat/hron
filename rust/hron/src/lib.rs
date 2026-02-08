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
    pub fn parse(input: &str) -> Result<Self, ScheduleError> {
        parser::parse(input)
    }

    /// Compute the next occurrence after `now`.
    pub fn next_from(&self, now: &Zoned) -> Option<Zoned> {
        eval::next_from(self, now).ok().flatten()
    }

    /// Compute the next `n` occurrences after `now`.
    pub fn next_n_from(&self, now: &Zoned, n: usize) -> Vec<Zoned> {
        eval::next_n_from(self, now, n).unwrap_or_default()
    }

    /// Check if a datetime matches this schedule.
    pub fn matches(&self, datetime: &Zoned) -> bool {
        eval::matches(self, datetime).unwrap_or(false)
    }

    /// Set the anchor date for multi-week intervals.
    pub fn with_anchor(mut self, date: jiff::civil::Date) -> Self {
        self.anchor = Some(date);
        self
    }

    /// Convert a 5-field cron expression to a Schedule.
    pub fn from_cron(cron_expr: &str) -> Result<Self, ScheduleError> {
        cron::from_cron(cron_expr)
    }

    /// Convert this schedule to a 5-field cron expression.
    pub fn to_cron(&self) -> Result<String, ScheduleError> {
        cron::to_cron(self)
    }

    /// Get the timezone for this schedule, if specified.
    pub fn timezone(&self) -> Option<&str> {
        self.timezone.as_deref()
    }
}

impl FromStr for Schedule {
    type Err = ScheduleError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse(s)
    }
}

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

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Schedule {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Deserialize from the expression string
        let s = String::deserialize(deserializer)?;
        Schedule::parse(&s).map_err(serde::de::Error::custom)
    }
}
