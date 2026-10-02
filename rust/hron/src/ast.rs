#[cfg(feature = "serde")]
use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub struct Schedule {
    pub(crate) expression: ScheduleExpr,
    pub(crate) timezone: Option<String>,
    pub(crate) except: Vec<Exception>,
    pub(crate) until: Option<UntilSpec>,
    pub(crate) starting: Option<jiff::civil::Date>,
    pub(crate) during: Vec<MonthName>,
}

/// The parts of a schedule, for [`Schedule::from_parts`] to check and build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScheduleParts {
    pub expression: ScheduleExpr,
    /// `UTC` or an IANA `Area/Location` name in any case.
    pub timezone: Option<String>,
    /// An empty list is no `except` clause.
    pub except: Vec<Exception>,
    pub until: Option<UntilSpec>,
    pub starting: Option<jiff::civil::Date>,
    /// An empty list is no `during` clause.
    pub during: Vec<MonthName>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum ScheduleExpr {
    IntervalRepeat {
        interval: u32,
        unit: IntervalUnit,
        from: TimeOfDay,
        to: TimeOfDay,
        day_filter: Option<DayFilter>,
    },
    DayRepeat {
        interval: u32,
        days: DayFilter,
        times: Vec<TimeOfDay>,
    },
    WeekRepeat {
        interval: u32,
        days: Vec<Weekday>,
        times: Vec<TimeOfDay>,
    },
    MonthRepeat {
        interval: u32,
        target: MonthTarget,
        times: Vec<TimeOfDay>,
    },
    SingleDate {
        date: DateSpec,
        times: Vec<TimeOfDay>,
    },
    YearRepeat {
        interval: u32,
        target: YearTarget,
        times: Vec<TimeOfDay>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum Exception {
    /// Matches this month and day every year.
    Named { month: MonthName, day: u8 },
    /// Matches only this date, as YYYY-MM-DD.
    Iso(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum UntilSpec {
    Iso(String),
    /// Resolves to the first such date on or after `starting`.
    Named {
        month: MonthName,
        day: u8,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum YearTarget {
    Date {
        month: MonthName,
        day: u8,
    },
    OrdinalWeekday {
        ordinal: OrdinalPosition,
        weekday: Weekday,
        month: MonthName,
    },
    DayOfMonth {
        day: u8,
        month: MonthName,
    },
    LastWeekday {
        month: MonthName,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
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
        let hour: u8 = parts[0]
            .parse()
            .map_err(|_| serde::de::Error::custom("invalid hour"))?;
        let minute: u8 = parts[1]
            .parse()
            .map_err(|_| serde::de::Error::custom("invalid minute"))?;
        Ok(TimeOfDay { hour, minute })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "lowercase"))]
pub enum DayFilter {
    Every,
    Weekday,
    Weekend,
    Days(Vec<Weekday>),
}

/// Serializes as its lowercase name.
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

    pub(crate) fn to_jiff(self) -> jiff::civil::Weekday {
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

    pub(crate) fn from_jiff(wd: jiff::civil::Weekday) -> Self {
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

pub(crate) fn parse_weekday(s: &str) -> Option<Weekday> {
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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum DayOfMonthSpec {
    Single(u8),
    Range(u8, u8),
}

impl DayOfMonthSpec {
    pub fn expand(&self) -> Vec<u8> {
        match self {
            DayOfMonthSpec::Single(d) => vec![*d],
            DayOfMonthSpec::Range(start, end) => (*start..=*end).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum NearestDirection {
    /// Always prefer following weekday (can cross to next month).
    Next,
    /// Always prefer preceding weekday (can cross to prev month).
    Previous,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
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
    OrdinalWeekday {
        ordinal: OrdinalPosition,
        weekday: Weekday,
    },
}

impl MonthTarget {
    pub(crate) fn expand_days(&self) -> Vec<u8> {
        match self {
            MonthTarget::Days(specs) => specs.iter().flat_map(|s| s.expand()).collect(),
            _ => vec![],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
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

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[non_exhaustive]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(rename_all = "snake_case"))]
pub enum DateSpec {
    Named { month: MonthName, day: u8 },
    Iso(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

    pub(crate) fn max_day(self) -> u8 {
        match self {
            Self::February => 29,
            Self::April | Self::June | Self::September | Self::November => 30,
            _ => 31,
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

pub(crate) fn parse_month_name(s: &str) -> Option<MonthName> {
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
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
}
