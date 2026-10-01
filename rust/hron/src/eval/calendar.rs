use jiff::civil::{Date, Weekday as CivilWeekday};
use jiff::Span;

use crate::ast::{DayFilter, MonthTarget, NearestDirection, OrdinalPosition, Weekday, YearTarget};

pub(super) fn add_days(date: Date, days: i64) -> Option<Date> {
    date.checked_add(Span::new().try_days(days).ok()?).ok()
}

pub(super) fn days_between(a: Date, b: Date) -> i64 {
    a.until(b).unwrap().get_days() as i64
}

pub(super) fn months_between(a: Date, b: Date) -> i64 {
    month_index(b) - month_index(a)
}

pub(super) fn month_index(date: Date) -> i64 {
    date.year() as i64 * 12 + date.month() as i64 - 1
}

pub(super) fn first_of_month_index(index: i64) -> Option<Date> {
    let year = i16::try_from(index.div_euclid(12)).ok()?;
    Date::new(year, index.rem_euclid(12) as i8 + 1, 1).ok()
}

pub(super) fn monday_of_week(date: Date) -> Option<Date> {
    add_days(date, -(date.weekday().to_monday_zero_offset() as i64))
}

pub(super) fn matches_day_filter(date: Date, filter: &DayFilter) -> bool {
    match filter {
        DayFilter::Every => true,
        DayFilter::Weekday => !is_weekend(date),
        DayFilter::Weekend => is_weekend(date),
        DayFilter::Days(days) => days.contains(&Weekday::from_jiff(date.weekday())),
    }
}

fn is_weekend(date: Date) -> bool {
    matches!(
        date.weekday(),
        CivilWeekday::Saturday | CivilWeekday::Sunday
    )
}

pub(super) fn month_target_dates(year: i16, month: i8, target: &MonthTarget) -> Vec<Date> {
    let mut dates: Vec<Date> = match target {
        MonthTarget::Days(_) => target
            .expand_days()
            .into_iter()
            .filter_map(|day| Date::new(year, month, day as i8).ok())
            .collect(),
        MonthTarget::LastDay => vec![last_day_of_month(year, month)],
        MonthTarget::LastWeekday => vec![last_weekday_of_month(year, month)],
        MonthTarget::NearestWeekday { day, direction } => {
            nearest_weekday(year, month, *day, *direction)
                .into_iter()
                .collect()
        }
        MonthTarget::OrdinalWeekday { ordinal, weekday } => {
            ordinal_weekday(year, month, *ordinal, *weekday)
                .into_iter()
                .collect()
        }
    };
    dates.sort();
    dates
}

pub(super) fn year_target_date(year: i16, target: &YearTarget) -> Option<Date> {
    match target {
        YearTarget::Date { month, day } | YearTarget::DayOfMonth { day, month } => {
            Date::new(year, month.number() as i8, *day as i8).ok()
        }
        YearTarget::OrdinalWeekday {
            ordinal,
            weekday,
            month,
        } => ordinal_weekday(year, month.number() as i8, *ordinal, *weekday),
        YearTarget::LastWeekday { month } => {
            Some(last_weekday_of_month(year, month.number() as i8))
        }
    }
}

fn last_day_of_month(year: i16, month: i8) -> Date {
    Date::new(year, month, 1).unwrap().last_of_month()
}

fn last_weekday_of_month(year: i16, month: i8) -> Date {
    let last = last_day_of_month(year, month);
    let back = match last.weekday() {
        CivilWeekday::Saturday => 1,
        CivilWeekday::Sunday => 2,
        _ => 0,
    };
    Date::new(year, month, last.day() - back).unwrap()
}

fn ordinal_weekday(
    year: i16,
    month: i8,
    ordinal: OrdinalPosition,
    weekday: Weekday,
) -> Option<Date> {
    let nth = match ordinal {
        OrdinalPosition::First => 1,
        OrdinalPosition::Second => 2,
        OrdinalPosition::Third => 3,
        OrdinalPosition::Fourth => 4,
        OrdinalPosition::Fifth => 5,
        OrdinalPosition::Last => -1,
    };
    Date::new(year, month, 1)
        .ok()?
        .nth_weekday_of_month(nth, weekday.to_jiff())
        .ok()
}

/// The weekday nearest `day` of a month, or None when the month is shorter.
/// Without a direction it stays in the month, as cron's `W` does; with one it
/// can cross into the adjacent month (spec/README.md, "Nearest weekday and `during`").
fn nearest_weekday(
    year: i16,
    month: i8,
    day: u8,
    toward: Option<NearestDirection>,
) -> Option<Date> {
    let date = Date::new(year, month, day as i8).ok()?;
    let shift = match (date.weekday(), toward) {
        (CivilWeekday::Saturday, Some(NearestDirection::Next)) => 2,
        (CivilWeekday::Saturday, Some(NearestDirection::Previous)) => -1,
        (CivilWeekday::Saturday, None) if date.day() == 1 => 2,
        (CivilWeekday::Saturday, None) => -1,
        (CivilWeekday::Sunday, Some(NearestDirection::Next)) => 1,
        (CivilWeekday::Sunday, Some(NearestDirection::Previous)) => -2,
        (CivilWeekday::Sunday, None) if date == date.last_of_month() => -2,
        (CivilWeekday::Sunday, None) => 1,
        _ => 0,
    };
    add_days(date, shift)
}
