//! hron — Human-readable cron.
//!
//! Human-readable schedule expressions that read like English and convert to and from cron.
//!
//! # Examples
//!
//! ```
//! use hron::Schedule;
//!
//! let schedule: Schedule = "every weekday at 09:00".parse().unwrap();
//! println!("{}", schedule); // "every weekday at 09:00"
//! ```
//!
//! [`Schedule::from_parts`] builds a schedule in code, checked by the rules
//! `parse` applies. Evaluating a schedule, parsed or built, never fails.

pub mod ast;
pub(crate) mod cron;
pub(crate) mod display;
pub mod error;
pub(crate) mod eval;
pub(crate) mod lexer;
pub(crate) mod parser;
pub(crate) mod parts;

pub use ast::{Schedule, ScheduleExpr, ScheduleParts};
pub use error::ScheduleError;
pub use eval::{BoundedOccurrences, Occurrences};

use jiff::Zoned;
#[cfg(feature = "serde")]
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::str::FromStr;

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
    /// let schedule = Schedule::parse("every day at 12:00 in UTC").unwrap();
    /// assert_eq!(schedule.timezone(), Some("UTC"));
    /// ```
    pub fn parse(input: &str) -> Result<Self, ScheduleError> {
        parser::parse(input)
    }

    /// Build a schedule from its parts, checked by the rules `parse` applies.
    ///
    /// Errors with an `eval` error, which has no span, for the first part that
    /// breaks a rule, in the order of spec/README.md, "Schedules built in code".
    /// The timezone is kept in the database's capitalization.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::ast::{DayFilter, TimeOfDay};
    /// use hron::{Schedule, ScheduleExpr, ScheduleParts};
    ///
    /// let schedule = Schedule::from_parts(ScheduleParts {
    ///     expression: ScheduleExpr::DayRepeat {
    ///         interval: 1,
    ///         days: DayFilter::Weekday,
    ///         times: vec![TimeOfDay { hour: 9, minute: 0 }],
    ///     },
    ///     timezone: Some("america/new_york".into()),
    ///     except: vec![],
    ///     until: None,
    ///     starting: None,
    ///     during: vec![],
    /// })
    /// .unwrap();
    /// assert_eq!(schedule.to_string(), "every weekday at 09:00 in America/New_York");
    ///
    /// let mut parts = schedule.to_parts();
    /// parts.timezone = Some("EST".into());
    /// assert_eq!(
    ///     Schedule::from_parts(parts).unwrap_err().to_string(),
    ///     "timezone must be UTC or an Area/Location name such as America/New_York, got EST"
    /// );
    /// ```
    pub fn from_parts(parts: ScheduleParts) -> Result<Self, ScheduleError> {
        parts::checked(parts).map(Self::from_valid_parts)
    }

    /// For `parse` and `from_cron`, whose parts already keep every rule.
    pub(crate) fn from_valid_parts(parts: ScheduleParts) -> Self {
        Self {
            expr: parts.expression,
            timezone: parts.timezone,
            except: parts.except,
            until: parts.until,
            anchor: parts.starting,
            during: parts.during,
        }
    }

    /// The parts this schedule was built from, to change and build again.
    pub fn to_parts(&self) -> ScheduleParts {
        ScheduleParts {
            expression: self.expr.clone(),
            timezone: self.timezone.clone(),
            except: self.except.clone(),
            until: self.until.clone(),
            starting: self.anchor,
            during: self.during.clone(),
        }
    }

    /// Compute the next occurrence strictly after `now`.
    ///
    /// Returns `None` when there are no future occurrences (e.g., past the
    /// `until` date), and when `now` or the occurrence is outside the supported
    /// range, 0001-01-02T00:00Z up to 9999-12-30T00:00Z.
    ///
    /// A fixed time in a DST spring-forward gap shifts forward by the length of
    /// the gap (02:30 becomes 03:30), while an interval slot in the gap is
    /// skipped. A time repeated by a fall-back transition occurs only at its
    /// first pass.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let now: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    /// let next = schedule.next_from(&now).unwrap();
    /// assert_eq!(next.to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// ```
    pub fn next_from(&self, now: &Zoned) -> Option<Zoned> {
        eval::next_from(self, now)
    }

    /// Compute the next `n` occurrences strictly after `now`.
    ///
    /// Returns fewer than `n` when the schedule has fewer occurrences left.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let now: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    /// let next_3 = schedule.next_n_from(&now, 3);
    /// assert_eq!(next_3.len(), 3);
    /// assert_eq!(next_3[0].to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// assert_eq!(next_3[2].to_string(), "2025-06-17T09:00:00+00:00[UTC]");
    /// ```
    pub fn next_n_from(&self, now: &Zoned, n: usize) -> Vec<Zoned> {
        eval::next_n_from(self, now, n)
    }

    /// Compute the most recent occurrence strictly before `now`.
    ///
    /// Returns `None` when there is no earlier occurrence in the supported range.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let now: jiff::Zoned = "2025-06-15T12:00:00+00:00[UTC]".parse().unwrap();
    /// let prev = schedule.previous_from(&now).unwrap();
    /// assert_eq!(prev.to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// ```
    pub fn previous_from(&self, now: &Zoned) -> Option<Zoned> {
        eval::previous_from(self, now)
    }

    /// Check whether the minute containing `datetime` is an occurrence of this
    /// schedule. Seconds on the schedule's wall clock are ignored, so 09:00:30
    /// matches `every day at 09:00`. False outside the supported range.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    ///
    /// let matching: jiff::Zoned = "2025-06-15T09:00:00+00:00[UTC]".parse().unwrap();
    /// assert!(schedule.matches(&matching));
    ///
    /// let non_matching: jiff::Zoned = "2025-06-15T10:00:00+00:00[UTC]".parse().unwrap();
    /// assert!(!schedule.matches(&non_matching));
    /// ```
    pub fn matches(&self, datetime: &Zoned) -> bool {
        eval::matches(self, datetime)
    }

    /// Check if an input string is a valid hron expression: false for anything
    /// `parse` rejects, including unknown timezones.
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

    /// Convert a 5-field cron expression to a Schedule that fires at the same times.
    ///
    /// Errors with a `cron` error when the input is not valid cron or has no
    /// exact hron equivalent.
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

    /// Explain a cron expression in human-readable form: the same as
    /// `Schedule::from_cron(cron_expr)?.to_string()`, with the same errors.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let explanation = Schedule::explain_cron("0 9 * * 1-5").unwrap();
    /// assert_eq!(explanation, "every weekday at 09:00");
    /// ```
    pub fn explain_cron(cron_expr: &str) -> Result<String, ScheduleError> {
        Ok(cron::from_cron(cron_expr)?.to_string())
    }

    /// Convert this schedule to a 5-field cron expression.
    ///
    /// Errors with a `cron` error when cron cannot fire at exactly the same times.
    /// The schedule's timezone is not part of the cron.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00").unwrap();
    /// assert_eq!(schedule.to_cron().unwrap(), "0 9 * * *");
    ///
    /// let schedule = Schedule::parse("every 2 weeks on monday at 09:00").unwrap();
    /// assert!(schedule.to_cron().is_err());
    /// ```
    pub fn to_cron(&self) -> Result<String, ScheduleError> {
        cron::to_cron(self)
    }

    /// The IANA timezone name in the timezone database's capitalization, or
    /// `None` if the schedule names none.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in america/new_york").unwrap();
    /// assert_eq!(schedule.timezone(), Some("America/New_York"));
    ///
    /// let schedule = Schedule::parse("every day at 09:00").unwrap();
    /// assert_eq!(schedule.timezone(), None);
    /// ```
    pub fn timezone(&self) -> Option<&str> {
        self.timezone.as_deref()
    }

    pub fn expr(&self) -> &ScheduleExpr {
        &self.expr
    }

    pub fn except(&self) -> &[ast::Exception] {
        &self.except
    }

    pub fn until(&self) -> Option<&ast::UntilSpec> {
        self.until.as_ref()
    }

    pub fn anchor(&self) -> Option<jiff::civil::Date> {
        self.anchor
    }

    pub fn during(&self) -> &[ast::MonthName] {
        &self.during
    }

    /// Returns a lazy iterator of occurrences strictly after `from`.
    ///
    /// Unbounded for repeating schedules unless an `until` clause ends them.
    ///
    /// # Examples
    ///
    /// ```
    /// use hron::Schedule;
    ///
    /// let schedule = Schedule::parse("every day at 09:00 in UTC").unwrap();
    /// let from: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse().unwrap();
    ///
    /// let first_5: Vec<_> = schedule.occurrences(&from).take(5).collect();
    /// assert_eq!(first_5.len(), 5);
    /// assert_eq!(first_5[0].to_string(), "2025-06-15T09:00:00+00:00[UTC]");
    /// ```
    pub fn occurrences(&self, from: &Zoned) -> eval::Occurrences<'_> {
        eval::Occurrences::new(self, from.clone())
    }

    /// Returns a bounded iterator of occurrences in the range `(from, to]`.
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
    /// let occurrences: Vec<_> = schedule.between(&from, &to).collect();
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

/// Serializes to a structured JSON object (`kind`, `interval`, `times`,
/// `except`, `timezone`, ...) for inspection and logging.
///
/// Deliberately asymmetric with `Deserialize`, which takes an hron expression
/// string, so serializing and then deserializing does not round-trip.
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

        // Always present, for a consistent JSON shape.
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

/// Deserializes from an hron expression string, not from the structured JSON
/// that `Serialize` produces.
#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Schedule {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Schedule::parse(&s).map_err(serde::de::Error::custom)
    }
}
