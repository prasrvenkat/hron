//! The checks of spec/README.md, "Schedules built in code", in its order.

use crate::ast::*;
use crate::display::ordinal_suffix;
use crate::error::ScheduleError;
use crate::parser::iana_timezone;

pub(crate) fn checked(parts: ScheduleParts) -> Result<ScheduleParts, ScheduleError> {
    check_expression(&parts.expression)?;
    for exception in &parts.except {
        match exception {
            Exception::Named { month, day } => check_named_date(*month, *day)?,
            Exception::Iso(date) => check_iso_date(date)?,
        }
    }
    match &parts.until {
        Some(UntilSpec::Named { month, day }) => check_named_date(*month, *day)?,
        Some(UntilSpec::Iso(date)) => check_iso_date(date)?,
        None => {}
    }
    if let Some(starting) = parts.starting {
        if starting.year() < 1 {
            return Err(date_error(&starting.to_string()));
        }
    }
    let timezone = match &parts.timezone {
        Some(name) => Some(iana_timezone(name).ok_or_else(|| {
            error(format!(
                "timezone must be UTC or an Area/Location name such as America/New_York, got {name}"
            ))
        })?),
        None => None,
    };
    if let (Some(UntilSpec::Named { month, day }), None) = (&parts.until, parts.starting) {
        return Err(error(format!(
            "until {} {day} has no year: add a starting date, or use an ISO date",
            month.as_str()
        )));
    }
    Ok(ScheduleParts { timezone, ..parts })
}

fn check_expression(expression: &ScheduleExpr) -> Result<(), ScheduleError> {
    match expression {
        ScheduleExpr::IntervalRepeat {
            interval,
            from,
            to,
            day_filter,
            ..
        } => {
            check_interval(*interval)?;
            check_time(from)?;
            check_time(to)?;
            if from > to {
                return Err(error(format!(
                    "time window must not run backwards: {from} to {to} (a window cannot cross midnight)"
                )));
            }
            if let Some(days) = day_filter {
                check_day_filter(days)?;
            }
            Ok(())
        }
        ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        } => {
            check_interval(*interval)?;
            // `every 2 days` has no place for a day filter, so other days would not survive display.
            if *interval > 1 && *days != DayFilter::Every {
                return Err(error("days must be every day when the interval is above 1"));
            }
            check_day_filter(days)?;
            check_times(times)
        }
        ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        } => {
            check_interval(*interval)?;
            check_days(days)?;
            check_times(times)
        }
        ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        } => {
            check_interval(*interval)?;
            check_month_target(target)?;
            check_times(times)
        }
        ScheduleExpr::SingleDate { date, times } => {
            match date {
                DateSpec::Named { month, day } => check_named_date(*month, *day)?,
                DateSpec::Iso(date) => check_iso_date(date)?,
            }
            check_times(times)
        }
        ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        } => {
            check_interval(*interval)?;
            check_year_target(target)?;
            check_times(times)
        }
    }
}

fn check_interval(interval: u32) -> Result<(), ScheduleError> {
    if interval == 0 || interval > i32::MAX as u32 {
        return Err(error(format!(
            "interval must be 1-2147483647, got {interval}"
        )));
    }
    Ok(())
}

fn check_times(times: &[TimeOfDay]) -> Result<(), ScheduleError> {
    if times.is_empty() {
        return Err(error("times must not be empty"));
    }
    times.iter().try_for_each(check_time)
}

fn check_time(time: &TimeOfDay) -> Result<(), ScheduleError> {
    if time.hour > 23 || time.minute > 59 {
        return Err(error(format!("time must be 00:00-23:59, got {time}")));
    }
    Ok(())
}

fn check_day_filter(filter: &DayFilter) -> Result<(), ScheduleError> {
    match filter {
        DayFilter::Days(days) => check_days(days),
        DayFilter::Every | DayFilter::Weekday | DayFilter::Weekend => Ok(()),
    }
}

fn check_days<T>(days: &[T]) -> Result<(), ScheduleError> {
    if days.is_empty() {
        return Err(error("days must not be empty"));
    }
    Ok(())
}

fn check_month_target(target: &MonthTarget) -> Result<(), ScheduleError> {
    match target {
        MonthTarget::Days(specs) => {
            check_days(specs)?;
            for spec in specs {
                match *spec {
                    DayOfMonthSpec::Single(day) => check_day(&ordinal(day), day)?,
                    DayOfMonthSpec::Range(start, end) => {
                        check_day(&ordinal(start), start)?;
                        check_day(&ordinal(end), end)?;
                        if start > end {
                            return Err(error(format!(
                                "day range must not run backwards: {} to {}",
                                ordinal(start),
                                ordinal(end)
                            )));
                        }
                    }
                }
            }
            Ok(())
        }
        MonthTarget::NearestWeekday { day, .. } => check_day(&ordinal(*day), *day),
        MonthTarget::LastDay | MonthTarget::LastWeekday | MonthTarget::OrdinalWeekday { .. } => {
            Ok(())
        }
    }
}

fn check_year_target(target: &YearTarget) -> Result<(), ScheduleError> {
    match target {
        YearTarget::Date { month, day } => check_named_date(*month, *day),
        YearTarget::DayOfMonth { day, month } => {
            check_day(&ordinal(*day), *day)?;
            check_day_in_month(&ordinal(*day), *day, *month)
        }
        YearTarget::OrdinalWeekday { .. } | YearTarget::LastWeekday { .. } => Ok(()),
    }
}

fn check_named_date(month: MonthName, day: u8) -> Result<(), ScheduleError> {
    check_day(&day.to_string(), day)?;
    check_day_in_month(&day.to_string(), day, month)
}

fn check_day(as_displayed: &str, day: u8) -> Result<(), ScheduleError> {
    if !(1..=31).contains(&day) {
        return Err(error(format!("day must be 1-31, got {as_displayed}")));
    }
    Ok(())
}

fn check_day_in_month(as_displayed: &str, day: u8, month: MonthName) -> Result<(), ScheduleError> {
    let max = month.max_day();
    if day > max {
        return Err(error(format!(
            "day must be 1-{max} for {}, got {as_displayed}",
            month.as_str()
        )));
    }
    Ok(())
}

/// jiff alone would also read `20260206`, `+002026-02-06` and `2026-02-06T10:00`.
fn check_iso_date(date: &str) -> Result<(), ScheduleError> {
    let bytes = date.as_bytes();
    let shaped = bytes.len() == 10
        && bytes.iter().enumerate().all(|(i, b)| match i {
            4 | 7 => *b == b'-',
            _ => b.is_ascii_digit(),
        });
    let calendar = shaped
        && date
            .parse::<jiff::civil::Date>()
            .is_ok_and(|date| date.year() >= 1);
    if !calendar {
        return Err(date_error(date));
    }
    Ok(())
}

fn date_error(date: &str) -> ScheduleError {
    error(format!(
        "date must be a calendar date from 0001-01-01 to 9999-12-31, got {date}"
    ))
}

fn ordinal(day: u8) -> String {
    format!("{day}{}", ordinal_suffix(day))
}

fn error(message: impl Into<String>) -> ScheduleError {
    ScheduleError::eval(message)
}
