#[cfg(feature = "serde")]
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A parsed hron schedule: expression + optional modifiers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Schedule {
    pub expr: ScheduleExpr,
    pub timezone: Option<String>,
    pub except: Vec<Exception>,
    pub until: Option<UntilSpec>,
    pub anchor: Option<jiff::civil::Date>,
    pub during: Vec<MonthName>,
}

impl Schedule {
    /// Create a Schedule from just an expression (no modifiers).
    pub fn new(expr: ScheduleExpr) -> Self {
        Self {
            expr,
            timezone: None,
            except: Vec::new(),
            until: None,
            anchor: None,
            during: Vec::new(),
        }
    }
}

/// The core schedule expression (what repeats).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScheduleExpr {
    /// `every 30 min from 09:00 to 17:00 [on weekdays]`
    IntervalRepeat {
        interval: u32,
        unit: IntervalUnit,
        from: TimeOfDay,
        to: TimeOfDay,
        day_filter: Option<DayFilter>,
    },
    /// `every day at 09:00`, `every 2 days at 09:00`
    DayRepeat {
        interval: u32,
        days: DayFilter,
        times: Vec<TimeOfDay>,
    },
    /// `every 2 weeks on monday at 09:00`
    WeekRepeat {
        interval: u32,
        days: Vec<Weekday>,
        times: Vec<TimeOfDay>,
    },
    /// `every month on the 1st at 09:00`, `every 2 months on the 1st at 09:00`
    MonthRepeat {
        interval: u32,
        target: MonthTarget,
        times: Vec<TimeOfDay>,
    },
    /// `first monday of every month at 10:00`, `first monday of every 2 months at 10:00`
    OrdinalRepeat {
        interval: u32,
        ordinal: OrdinalPosition,
        day: Weekday,
        times: Vec<TimeOfDay>,
    },
    /// `on feb 14 at 9:00, 17:00`
    SingleDate {
        date: DateSpec,
        times: Vec<TimeOfDay>,
    },
    /// `every year on dec 25 at 00:00`, `every 2 years on dec 25 at 00:00`
    YearRepeat {
        interval: u32,
        target: YearTarget,
        times: Vec<TimeOfDay>,
    },
}

/// Exception date for `except` clause.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum Exception {
    /// Recurring named date: `dec 25` matches every year.
    Named { month: MonthName, day: u8 },
    /// One-off ISO date: `2026-12-25`.
    Iso(String),
}

/// Until spec for `until` clause.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum UntilSpec {
    /// ISO date: `2026-12-31`.
    Iso(String),
    /// Named date: `dec 31` — resolves to next occurrence from current year.
    Named { month: MonthName, day: u8 },
}

/// Year target for yearly expressions.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum YearTarget {
    /// `on dec 25` — specific month and day.
    Date { month: MonthName, day: u8 },
    /// `on the first monday of march` — ordinal weekday of a month.
    OrdinalWeekday {
        ordinal: OrdinalPosition,
        weekday: Weekday,
        month: MonthName,
    },
    /// `on the 15th of march` — day of a month.
    DayOfMonth { day: u8, month: MonthName },
    /// `on the last weekday of december` — last weekday of a month.
    LastWeekday { month: MonthName },
}

/// Time of day (hours and minutes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeOfDay {
    pub hour: u8,
    pub minute: u8,
}

#[cfg(feature = "serde")]
impl Serialize for TimeOfDay {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format!("{:02}:{:02}", self.hour, self.minute))
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for TimeOfDay {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() != 2 {
            return Err(serde::de::Error::custom("expected HH:MM"));
        }
        let hour = parts[0]
            .parse()
            .map_err(|_| serde::de::Error::custom("invalid hour"))?;
        let minute = parts[1]
            .parse()
            .map_err(|_| serde::de::Error::custom("invalid minute"))?;
        Ok(TimeOfDay { hour, minute })
    }
}

/// Day filter for day-repeat and interval expressions.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum DayFilter {
    Every,
    Weekday,
    Weekend,
    Days(Vec<Weekday>),
}

/// Weekday with custom serde (lowercase string).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Weekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl Weekday {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Monday => "monday",
            Self::Tuesday => "tuesday",
            Self::Wednesday => "wednesday",
            Self::Thursday => "thursday",
            Self::Friday => "friday",
            Self::Saturday => "saturday",
            Self::Sunday => "sunday",
        }
    }

    pub fn short(self) -> &'static str {
        match self {
            Self::Monday => "mon",
            Self::Tuesday => "tue",
            Self::Wednesday => "wed",
            Self::Thursday => "thu",
            Self::Friday => "fri",
            Self::Saturday => "sat",
            Self::Sunday => "sun",
        }
    }

    pub fn to_jiff(self) -> jiff::civil::Weekday {
        match self {
            Self::Monday => jiff::civil::Weekday::Monday,
            Self::Tuesday => jiff::civil::Weekday::Tuesday,
            Self::Wednesday => jiff::civil::Weekday::Wednesday,
            Self::Thursday => jiff::civil::Weekday::Thursday,
            Self::Friday => jiff::civil::Weekday::Friday,
            Self::Saturday => jiff::civil::Weekday::Saturday,
            Self::Sunday => jiff::civil::Weekday::Sunday,
        }
    }

    pub fn from_jiff(wd: jiff::civil::Weekday) -> Self {
        match wd {
            jiff::civil::Weekday::Monday => Self::Monday,
            jiff::civil::Weekday::Tuesday => Self::Tuesday,
            jiff::civil::Weekday::Wednesday => Self::Wednesday,
            jiff::civil::Weekday::Thursday => Self::Thursday,
            jiff::civil::Weekday::Friday => Self::Friday,
            jiff::civil::Weekday::Saturday => Self::Saturday,
            jiff::civil::Weekday::Sunday => Self::Sunday,
        }
    }

    /// ISO 8601 day number: Monday=1, Sunday=7.
    pub fn number(self) -> u8 {
        match self {
            Self::Monday => 1,
            Self::Tuesday => 2,
            Self::Wednesday => 3,
            Self::Thursday => 4,
            Self::Friday => 5,
            Self::Saturday => 6,
            Self::Sunday => 7,
        }
    }

    pub fn from_number(n: u8) -> Option<Self> {
        match n {
            1 => Some(Self::Monday),
            2 => Some(Self::Tuesday),
            3 => Some(Self::Wednesday),
            4 => Some(Self::Thursday),
            5 => Some(Self::Friday),
            6 => Some(Self::Saturday),
            7 => Some(Self::Sunday),
            _ => None,
        }
    }

    pub fn all_weekdays() -> Vec<Self> {
        vec![
            Self::Monday,
            Self::Tuesday,
            Self::Wednesday,
            Self::Thursday,
            Self::Friday,
        ]
    }

    pub fn all_weekend() -> Vec<Self> {
        vec![Self::Saturday, Self::Sunday]
    }
}

#[cfg(feature = "serde")]
impl Serialize for Weekday {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

#[cfg(feature = "serde")]
impl<'de> Deserialize<'de> for Weekday {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        parse_weekday(&s).ok_or_else(|| serde::de::Error::custom(format!("unknown weekday: {s}")))
    }
}

pub fn parse_weekday(s: &str) -> Option<Weekday> {
    match s.to_lowercase().as_str() {
        "monday" | "mon" => Some(Weekday::Monday),
        "tuesday" | "tue" => Some(Weekday::Tuesday),
        "wednesday" | "wed" => Some(Weekday::Wednesday),
        "thursday" | "thu" => Some(Weekday::Thursday),
        "friday" | "fri" => Some(Weekday::Friday),
        "saturday" | "sat" => Some(Weekday::Saturday),
        "sunday" | "sun" => Some(Weekday::Sunday),
        _ => None,
    }
}

/// A single day or range of days in a monthly target.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum DayOfMonthSpec {
    Single(u8),
    Range(u8, u8),
}

impl DayOfMonthSpec {
    /// Expand into individual day numbers.
    pub fn expand(&self) -> Vec<u8> {
        match self {
            DayOfMonthSpec::Single(d) => vec![*d],
            DayOfMonthSpec::Range(start, end) => (*start..=*end).collect(),
        }
    }
}

/// Direction for nearest weekday (hron extension beyond cron W).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum NearestDirection {
    /// Always prefer following weekday (can cross to next month).
    Next,
    /// Always prefer preceding weekday (can cross to prev month).
    Previous,
}

/// Month target for month-repeat expressions.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum MonthTarget {
    Days(Vec<DayOfMonthSpec>),
    LastDay,
    LastWeekday,
    /// Nearest weekday to a given day of month.
    /// Standard (None): never crosses month boundary (cron W compatibility).
    /// Directional (Some): can cross month boundary.
    NearestWeekday {
        day: u8,
        direction: Option<NearestDirection>,
    },
}

impl MonthTarget {
    /// Expand all day specs into individual day numbers.
    pub fn expand_days(&self) -> Vec<u8> {
        match self {
            MonthTarget::Days(specs) => specs.iter().flat_map(|s| s.expand()).collect(),
            _ => vec![],
        }
    }
}

/// Ordinal position (first through fifth, or last).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum OrdinalPosition {
    First,
    Second,
    Third,
    Fourth,
    Fifth,
    Last,
}

impl OrdinalPosition {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::First => "first",
            Self::Second => "second",
            Self::Third => "third",
            Self::Fourth => "fourth",
            Self::Fifth => "fifth",
            Self::Last => "last",
        }
    }
}

/// Date specification for single-date expressions.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum DateSpec {
    Named { month: MonthName, day: u8 },
    Iso(String),
}

/// Month name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum MonthName {
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

impl MonthName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::January => "jan",
            Self::February => "feb",
            Self::March => "mar",
            Self::April => "apr",
            Self::May => "may",
            Self::June => "jun",
            Self::July => "jul",
            Self::August => "aug",
            Self::September => "sep",
            Self::October => "oct",
            Self::November => "nov",
            Self::December => "dec",
        }
    }

    pub fn number(self) -> u8 {
        match self {
            Self::January => 1,
            Self::February => 2,
            Self::March => 3,
            Self::April => 4,
            Self::May => 5,
            Self::June => 6,
            Self::July => 7,
            Self::August => 8,
            Self::September => 9,
            Self::October => 10,
            Self::November => 11,
            Self::December => 12,
        }
    }
}

pub fn parse_month_name(s: &str) -> Option<MonthName> {
    match s.to_lowercase().as_str() {
        "january" | "jan" => Some(MonthName::January),
        "february" | "feb" => Some(MonthName::February),
        "march" | "mar" => Some(MonthName::March),
        "april" | "apr" => Some(MonthName::April),
        "may" => Some(MonthName::May),
        "june" | "jun" => Some(MonthName::June),
        "july" | "jul" => Some(MonthName::July),
        "august" | "aug" => Some(MonthName::August),
        "september" | "sep" => Some(MonthName::September),
        "october" | "oct" => Some(MonthName::October),
        "november" | "nov" => Some(MonthName::November),
        "december" | "dec" => Some(MonthName::December),
        _ => None,
    }
}

/// Interval unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum IntervalUnit {
    Minutes,
    Hours,
}

impl IntervalUnit {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Minutes => "min",
            Self::Hours => "hours",
        }
    }

    pub fn singular(self) -> &'static str {
        match self {
            Self::Minutes => "minute",
            Self::Hours => "hour",
        }
    }
}
