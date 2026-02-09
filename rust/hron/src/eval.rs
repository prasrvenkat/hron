use std::sync::LazyLock;

use jiff::civil::{Date, Time};
use jiff::tz::TimeZone;
use jiff::Zoned;

use crate::ast::*;
use crate::error::ScheduleError;

/// Epoch anchor for multi-week intervals: Monday 1970-01-05.
static EPOCH_MONDAY: LazyLock<Date> = LazyLock::new(|| Date::new(1970, 1, 5).unwrap());

/// Epoch anchor for day/month/year intervals: 1970-01-01.
static EPOCH_DATE: LazyLock<Date> = LazyLock::new(|| Date::new(1970, 1, 1).unwrap());

/// Resolve the timezone for a schedule, falling back to system local.
fn resolve_tz(tz: &Option<String>) -> Result<TimeZone, ScheduleError> {
    match tz {
        Some(name) => TimeZone::get(name)
            .map_err(|e| ScheduleError::eval(format!("invalid timezone '{name}': {e}"))),
        None => Ok(TimeZone::system()),
    }
}

/// Convert TimeOfDay to jiff Time.
fn to_time(tod: &TimeOfDay) -> Time {
    Time::new(tod.hour as i8, tod.minute as i8, 0, 0).unwrap()
}

/// Set the time on a date in a timezone, returning a Zoned datetime.
fn at_time_on_date(date: Date, time: Time, tz: &TimeZone) -> Result<Zoned, ScheduleError> {
    let dt = date.to_datetime(time);
    dt.to_zoned(tz.clone())
        .map_err(|e| ScheduleError::eval(format!("cannot create zoned datetime: {e}")))
}

/// Check if a date's weekday matches the day filter.
fn matches_day_filter(date: Date, filter: &DayFilter) -> bool {
    let wd = Weekday::from_jiff(date.weekday());
    match filter {
        DayFilter::Every => true,
        DayFilter::Weekday => matches!(
            wd,
            Weekday::Monday
                | Weekday::Tuesday
                | Weekday::Wednesday
                | Weekday::Thursday
                | Weekday::Friday
        ),
        DayFilter::Weekend => matches!(wd, Weekday::Saturday | Weekday::Sunday),
        DayFilter::Days(days) => days.contains(&wd),
    }
}

/// Get the last day of a month.
fn last_day_of_month(year: i16, month: i8) -> Date {
    if month == 12 {
        Date::new(year + 1, 1, 1).unwrap().yesterday().unwrap()
    } else {
        Date::new(year, month + 1, 1).unwrap().yesterday().unwrap()
    }
}

/// Get the last weekday (Mon-Fri) of a month.
fn last_weekday_of_month(year: i16, month: i8) -> Date {
    let mut d = last_day_of_month(year, month);
    loop {
        let wd = d.weekday();
        if wd != jiff::civil::Weekday::Saturday && wd != jiff::civil::Weekday::Sunday {
            return d;
        }
        d = d.yesterday().unwrap();
    }
}

/// Get the nth weekday of a month (1-indexed). Returns None if it doesn't exist.
fn nth_weekday_of_month(year: i16, month: i8, weekday: Weekday, n: u8) -> Option<Date> {
    let target_wd = weekday.to_jiff();
    // Find first occurrence
    let first = Date::new(year, month, 1).ok()?;
    let mut d = first;
    while d.weekday() != target_wd {
        d = d.tomorrow().ok()?;
    }
    // Advance to nth
    for _ in 1..n {
        d = d.checked_add(jiff::Span::new().days(7)).ok()?;
    }
    // Check still in same month
    if d.month() != month {
        None
    } else {
        Some(d)
    }
}

/// Get the last occurrence of a weekday in a month.
fn last_weekday_in_month(year: i16, month: i8, weekday: Weekday) -> Date {
    let target_wd = weekday.to_jiff();
    let mut d = last_day_of_month(year, month);
    while d.weekday() != target_wd {
        d = d.yesterday().unwrap();
    }
    d
}

/// Count ISO weeks between two dates.
fn weeks_between(a: Date, b: Date) -> i64 {
    let span = a.until(b).unwrap();
    span.get_days() as i64 / 7
}

/// Count days between two dates (signed).
fn days_between(a: Date, b: Date) -> i64 {
    a.until(b).unwrap().get_days() as i64
}

/// Count months between two dates (year*12+month arithmetic).
fn months_between_ym(a: Date, b: Date) -> i64 {
    (b.year() as i64 * 12 + b.month() as i64) - (a.year() as i64 * 12 + a.month() as i64)
}

/// Pre-parsed exception data to avoid re-parsing ISO strings on every check.
struct ParsedExceptions {
    named: Vec<(u8, u8)>, // (month_number, day)
    iso_dates: Vec<Date>,
}

impl ParsedExceptions {
    fn from_exceptions(exceptions: &[Exception]) -> Self {
        let mut named = Vec::new();
        let mut iso_dates = Vec::new();
        for exc in exceptions {
            match exc {
                Exception::Named { month, day } => {
                    named.push((month.number(), *day));
                }
                Exception::Iso(s) => {
                    if let Ok(d) = s.parse::<Date>() {
                        iso_dates.push(d);
                    }
                }
            }
        }
        ParsedExceptions { named, iso_dates }
    }

    fn is_excepted(&self, date: Date) -> bool {
        for &(m, d) in &self.named {
            if date.month() == m as i8 && date.day() == d as i8 {
                return true;
            }
        }
        for &exc_date in &self.iso_dates {
            if date == exc_date {
                return true;
            }
        }
        false
    }
}

/// Check if a date matches any exception.
fn is_excepted(date: Date, exceptions: &[Exception]) -> bool {
    for exc in exceptions {
        match exc {
            Exception::Named { month, day } => {
                if date.month() == month.number() as i8 && date.day() == *day as i8 {
                    return true;
                }
            }
            Exception::Iso(s) => {
                if let Ok(exc_date) = s.parse::<Date>() {
                    if date == exc_date {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// Check if a date's month is in the `during` list.
/// If `during` is empty, all months match.
fn matches_during(date: Date, during: &[MonthName]) -> bool {
    if during.is_empty() {
        return true;
    }
    let m = date.month() as u8;
    during.iter().any(|mn| mn.number() == m)
}

/// Find the 1st of the next valid `during` month after `date`.
fn next_during_month(date: Date, during: &[MonthName]) -> Date {
    let current_month = date.month() as u8;
    let mut months: Vec<u8> = during.iter().map(|mn| mn.number()).collect();
    months.sort();

    // Find first month > current_month
    for &m in &months {
        if m > current_month {
            return Date::new(date.year(), m as i8, 1).unwrap();
        }
    }
    // Wrap to first month of next year
    Date::new(date.year() + 1, months[0] as i8, 1).unwrap()
}

/// Resolve an UntilSpec to a concrete Date.
fn resolve_until(until: &UntilSpec, now: &Zoned) -> Result<Date, ScheduleError> {
    match until {
        UntilSpec::Iso(s) => s
            .parse()
            .map_err(|e| ScheduleError::eval(format!("invalid until date '{s}': {e}"))),
        UntilSpec::Named { month, day } => {
            let year = now.date().year();
            // Try this year first, then next year
            for y in [year, year + 1] {
                if let Ok(d) = Date::new(y, month.number() as i8, *day as i8) {
                    if d >= now.date() {
                        return Ok(d);
                    }
                }
            }
            // Fallback: next year
            Date::new(year + 1, month.number() as i8, *day as i8)
                .map_err(|e| ScheduleError::eval(format!("invalid until date: {e}")))
        }
    }
}

/// Check if a datetime matches any of the scheduled times, accounting for DST gaps.
///
/// A time matches if either:
/// 1. The wall-clock time matches exactly (hour and minute), or
/// 2. The scheduled time falls in a DST gap and resolves to the candidate's time
///    (e.g., scheduled 2:00 AM during spring-forward resolves to 3:00 AM).
fn time_matches_with_dst(
    date: Date,
    times: &[TimeOfDay],
    tz: &TimeZone,
    zdt: &Zoned,
) -> Result<bool, ScheduleError> {
    for tod in times {
        let t = to_time(tod);
        // Direct wall-clock match
        if zdt.time().hour() == t.hour() && zdt.time().minute() == t.minute() {
            return Ok(true);
        }
        // DST gap check: resolve the scheduled time on this date and compare
        // the resulting instant. Covers cases where e.g. 2:00 AM → 3:00 AM.
        let resolved = at_time_on_date(date, t, tz)?;
        if resolved.timestamp() == zdt.timestamp() {
            return Ok(true);
        }
    }
    Ok(false)
}

/// For a given date, generate candidates at all given times and return the earliest one > now.
fn earliest_future_at_times(
    date: Date,
    times: &[TimeOfDay],
    tz: &TimeZone,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let mut best: Option<Zoned> = None;
    for tod in times {
        let t = to_time(tod);
        let candidate = at_time_on_date(date, t, tz)?;
        if candidate > *now {
            best = Some(match best {
                Some(prev) if candidate < prev => candidate,
                Some(prev) => prev,
                None => candidate,
            });
        }
    }
    Ok(best)
}

/// Compute next occurrence from `now` for a given schedule.
pub fn next_from(schedule: &Schedule, now: &Zoned) -> Result<Option<Zoned>, ScheduleError> {
    let tz = resolve_tz(&schedule.timezone)?;
    let anchor = schedule.anchor;

    // Resolve until date if present
    let until_date = match &schedule.until {
        Some(until) => Some(resolve_until(until, now)?),
        None => None,
    };

    let parsed_exceptions = ParsedExceptions::from_exceptions(&schedule.except);
    let has_exceptions = !schedule.except.is_empty();
    let has_during = !schedule.during.is_empty();
    let needs_tz_conversion = until_date.is_some() || has_during || has_exceptions;

    // Retry loop for exceptions and during filter: if candidate is filtered, skip and retry
    let mut current = now.clone();
    for _ in 0..1000 {
        let candidate = next_expr(&schedule.expr, &tz, &anchor, &current)?;

        let candidate = match candidate {
            Some(c) => c,
            None => return Ok(None),
        };

        // Convert to target tz once for all filter checks
        let c_date = if needs_tz_conversion {
            Some(candidate.with_time_zone(tz.clone()).date())
        } else {
            None
        };

        // Apply until filter
        if let Some(ref until) = until_date {
            if c_date.unwrap() > *until {
                return Ok(None);
            }
        }

        // Apply during filter
        if has_during && !matches_during(c_date.unwrap(), &schedule.during) {
            // Skip ahead to 1st of next valid during month
            let skip_to = next_during_month(c_date.unwrap(), &schedule.during);
            current = at_time_on_date(skip_to, Time::new(0, 0, 0, 0).unwrap(), &tz)?
                .checked_add(jiff::Span::new().seconds(-1))
                .map_err(|e| ScheduleError::eval(format!("{e}")))?;
            continue;
        }

        // Apply except filter
        if has_exceptions && parsed_exceptions.is_excepted(c_date.unwrap()) {
            // Advance past this day and retry
            let next_day = c_date
                .unwrap()
                .tomorrow()
                .map_err(|e| ScheduleError::eval(format!("{e}")))?;
            current = at_time_on_date(next_day, Time::new(0, 0, 0, 0).unwrap(), &tz)?
                .checked_add(jiff::Span::new().seconds(-1))
                .map_err(|e| ScheduleError::eval(format!("{e}")))?;
            continue;
        }

        return Ok(Some(candidate));
    }

    // Exhausted retry limit — every candidate was filtered by exceptions or
    // during-clause. This includes contradictory schedules (e.g. "on feb 14
    // during mar") where no occurrence can ever match. Treat as "no more
    // occurrences" rather than an error.
    Ok(None)
}

/// Compute next occurrence for the expression part only.
fn next_expr(
    expr: &ScheduleExpr,
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    match expr {
        ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        } => next_day_repeat(*interval, days, times, tz, anchor, now),

        ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            day_filter,
        } => next_interval_repeat(*interval, *unit, from, to, day_filter, tz, now),

        ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        } => next_week_repeat(*interval, days, times, tz, anchor, now),

        ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        } => next_month_repeat(*interval, target, times, tz, anchor, now),

        ScheduleExpr::OrdinalRepeat {
            interval,
            ordinal,
            day,
            times,
        } => next_ordinal_repeat(*interval, *ordinal, *day, times, tz, anchor, now),

        ScheduleExpr::SingleDate { date, times } => next_single_date(date, times, tz, now),

        ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        } => next_year_repeat(*interval, target, times, tz, anchor, now),
    }
}

/// Compute next N occurrences.
pub fn next_n_from(
    schedule: &Schedule,
    now: &Zoned,
    n: usize,
) -> Result<Vec<Zoned>, ScheduleError> {
    let mut results = Vec::with_capacity(n);
    let mut current = now.clone();
    for _ in 0..n {
        match next_from(schedule, &current)? {
            Some(next) => {
                // Advance current to just after this occurrence
                current = next
                    .checked_add(jiff::Span::new().minutes(1))
                    .map_err(|e| ScheduleError::eval(format!("overflow: {e}")))?;
                results.push(next);
            }
            None => break,
        }
    }
    Ok(results)
}

/// Check if a datetime matches the schedule.
pub fn matches(schedule: &Schedule, datetime: &Zoned) -> Result<bool, ScheduleError> {
    let tz = resolve_tz(&schedule.timezone)?;
    let zdt = datetime.with_time_zone(tz.clone());
    let date = zdt.date();

    // Check during filter
    if !matches_during(date, &schedule.during) {
        return Ok(false);
    }

    // Check exceptions
    if is_excepted(date, &schedule.except) {
        return Ok(false);
    }

    // Check until
    if let Some(ref until) = schedule.until {
        let until_date = resolve_until(until, datetime)?;
        if date > until_date {
            return Ok(false);
        }
    }

    match &schedule.expr {
        ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        } => {
            if !matches_day_filter(date, days) {
                return Ok(false);
            }
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            if *interval > 1 {
                let anchor_date = schedule.anchor.unwrap_or(*EPOCH_DATE);
                let day_offset = days_between(anchor_date, date);
                return Ok(day_offset >= 0 && day_offset % (*interval as i64) == 0);
            }
            Ok(true)
        }
        ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            day_filter,
        } => {
            if let Some(df) = day_filter {
                if !matches_day_filter(date, df) {
                    return Ok(false);
                }
            }
            let from_t = to_time(from);
            let to_t = to_time(to);
            let current_t = Time::new(zdt.time().hour(), zdt.time().minute(), 0, 0).unwrap();
            if current_t < from_t || current_t > to_t {
                return Ok(false);
            }
            let from_minutes = from_t.hour() as i32 * 60 + from_t.minute() as i32;
            let current_minutes = current_t.hour() as i32 * 60 + current_t.minute() as i32;
            let diff = current_minutes - from_minutes;
            let step = match unit {
                IntervalUnit::Minutes => *interval as i32,
                IntervalUnit::Hours => *interval as i32 * 60,
            };
            Ok(diff >= 0 && diff % step == 0)
        }
        ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        } => {
            let wd = Weekday::from_jiff(date.weekday());
            if !days.contains(&wd) {
                return Ok(false);
            }
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            let anchor_date = schedule.anchor.unwrap_or(*EPOCH_MONDAY);
            let weeks = weeks_between(anchor_date, date);
            Ok(weeks >= 0 && weeks % (*interval as i64) == 0)
        }
        ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        } => {
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            if *interval > 1 {
                let anchor_date = schedule.anchor.unwrap_or(*EPOCH_DATE);
                let month_offset = months_between_ym(anchor_date, date);
                if month_offset < 0 || month_offset % (*interval as i64) != 0 {
                    return Ok(false);
                }
            }
            match target {
                MonthTarget::Days(_) => {
                    let expanded = target.expand_days();
                    Ok(expanded.contains(&(date.day() as u8)))
                }
                MonthTarget::LastDay => {
                    let last = last_day_of_month(date.year(), date.month());
                    Ok(date == last)
                }
                MonthTarget::LastWeekday => {
                    let last_wd = last_weekday_of_month(date.year(), date.month());
                    Ok(date == last_wd)
                }
            }
        }
        ScheduleExpr::OrdinalRepeat {
            interval,
            ordinal,
            day,
            times,
        } => {
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            if *interval > 1 {
                let anchor_date = schedule.anchor.unwrap_or(*EPOCH_DATE);
                let month_offset = months_between_ym(anchor_date, date);
                if month_offset < 0 || month_offset % (*interval as i64) != 0 {
                    return Ok(false);
                }
            }
            let target_date = match ordinal {
                OrdinalPosition::Last => last_weekday_in_month(date.year(), date.month(), *day),
                _ => {
                    let n = ordinal_to_n(*ordinal);
                    match nth_weekday_of_month(date.year(), date.month(), *day, n) {
                        Some(d) => d,
                        None => return Ok(false),
                    }
                }
            };
            Ok(date == target_date)
        }
        ScheduleExpr::SingleDate {
            date: date_spec,
            times,
        } => {
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            match date_spec {
                DateSpec::Iso(s) => {
                    let target: Date = s
                        .parse()
                        .map_err(|e| ScheduleError::eval(format!("invalid date '{s}': {e}")))?;
                    Ok(date == target)
                }
                DateSpec::Named { month, day } => {
                    Ok(date.month() == month.number() as i8 && date.day() == *day as i8)
                }
            }
        }
        ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        } => {
            if !time_matches_with_dst(date, times, &tz, &zdt)? {
                return Ok(false);
            }
            if *interval > 1 {
                let anchor_year = schedule.anchor.unwrap_or(*EPOCH_DATE).year();
                let year_offset = date.year() as i64 - anchor_year as i64;
                if year_offset < 0 || year_offset % (*interval as i64) != 0 {
                    return Ok(false);
                }
            }
            match target {
                YearTarget::Date { month, day } => {
                    Ok(date.month() == month.number() as i8 && date.day() == *day as i8)
                }
                YearTarget::OrdinalWeekday {
                    ordinal,
                    weekday,
                    month,
                } => {
                    if date.month() != month.number() as i8 {
                        return Ok(false);
                    }
                    let target_date = match ordinal {
                        OrdinalPosition::Last => {
                            last_weekday_in_month(date.year(), date.month(), *weekday)
                        }
                        _ => {
                            match nth_weekday_of_month(
                                date.year(),
                                date.month(),
                                *weekday,
                                ordinal_to_n(*ordinal),
                            ) {
                                Some(d) => d,
                                None => return Ok(false),
                            }
                        }
                    };
                    Ok(date == target_date)
                }
                YearTarget::DayOfMonth { day, month } => {
                    Ok(date.month() == month.number() as i8 && date.day() == *day as i8)
                }
                YearTarget::LastWeekday { month } => {
                    if date.month() != month.number() as i8 {
                        return Ok(false);
                    }
                    let target_date = last_weekday_of_month(date.year(), date.month());
                    Ok(date == target_date)
                }
            }
        }
    }
}

fn ordinal_to_n(ord: OrdinalPosition) -> u8 {
    match ord {
        OrdinalPosition::First => 1,
        OrdinalPosition::Second => 2,
        OrdinalPosition::Third => 3,
        OrdinalPosition::Fourth => 4,
        OrdinalPosition::Fifth => 5,
        OrdinalPosition::Last => unreachable!(),
    }
}

// --- Eval helpers for each schedule variant ---

fn next_day_repeat(
    interval: u32,
    days: &DayFilter,
    times: &[TimeOfDay],
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());
    let mut date = now_in_tz.date();

    if interval <= 1 {
        // Original behavior for interval=1
        if matches_day_filter(date, days) {
            if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                return Ok(Some(candidate));
            }
        }
        for _ in 0..8 {
            date = date
                .tomorrow()
                .map_err(|e| ScheduleError::eval(format!("{e}")))?;
            if matches_day_filter(date, days) {
                if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                    return Ok(Some(candidate));
                }
            }
        }
        return Ok(None);
    }

    // Interval > 1: day intervals only apply to DayFilter::Every.
    // O(1) alignment via modular arithmetic: compute the next aligned day
    // >= today, then check at most 2 dates (today's aligned date if time
    // hasn't passed, otherwise the next aligned date).
    let anchor_date = anchor.unwrap_or(*EPOCH_DATE);
    let interval_i64 = interval as i64;

    let offset = days_between(anchor_date, date);
    let remainder = offset.rem_euclid(interval_i64);
    let aligned_date = if remainder == 0 {
        date
    } else {
        date.checked_add(jiff::Span::new().days(interval_i64 - remainder))
            .map_err(|e| ScheduleError::eval(format!("{e}")))?
    };

    // At most 2 iterations: aligned_date (if time hasn't passed) or next aligned date.
    let mut cur = aligned_date;
    for _ in 0..2 {
        if let Some(candidate) = earliest_future_at_times(cur, times, tz, now)? {
            return Ok(Some(candidate));
        }
        cur = cur
            .checked_add(jiff::Span::new().days(interval_i64))
            .map_err(|e| ScheduleError::eval(format!("{e}")))?;
    }

    Ok(None)
}

fn next_interval_repeat(
    interval: u32,
    unit: IntervalUnit,
    from: &TimeOfDay,
    to: &TimeOfDay,
    day_filter: &Option<DayFilter>,
    tz: &TimeZone,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());
    let from_t = to_time(from);
    let to_t = to_time(to);
    let step_minutes: i64 = match unit {
        IntervalUnit::Minutes => interval as i64,
        IntervalUnit::Hours => interval as i64 * 60,
    };

    let from_minutes = from_t.hour() as i64 * 60 + from_t.minute() as i64;
    let to_minutes = to_t.hour() as i64 * 60 + to_t.minute() as i64;
    let mut date = now_in_tz.date();

    // Search up to 400 days forward (covers weekday gaps, etc.)
    for _ in 0..400 {
        if let Some(df) = day_filter {
            if !matches_day_filter(date, df) {
                date = date
                    .tomorrow()
                    .map_err(|e| ScheduleError::eval(format!("{e}")))?;
                continue;
            }
        }

        // Compute the next valid slot
        let now_minutes = if date == now_in_tz.date() {
            now_in_tz.time().hour() as i64 * 60 + now_in_tz.time().minute() as i64
        } else {
            -1 // Future day: any slot from `from` is valid
        };

        let next_slot = if now_minutes < from_minutes {
            from_minutes
        } else {
            let elapsed = now_minutes - from_minutes;
            from_minutes + (elapsed / step_minutes + 1) * step_minutes
        };

        if next_slot <= to_minutes {
            let h = (next_slot / 60) as i8;
            let m = (next_slot % 60) as i8;
            let t = Time::new(h, m, 0, 0).unwrap();
            let candidate = at_time_on_date(date, t, tz)?;
            if candidate > *now {
                return Ok(Some(candidate));
            }
        }

        date = date
            .tomorrow()
            .map_err(|e| ScheduleError::eval(format!("{e}")))?;
    }

    Ok(None)
}

fn next_week_repeat(
    interval: u32,
    days: &[Weekday],
    times: &[TimeOfDay],
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());
    let anchor_date = anchor.unwrap_or(*EPOCH_MONDAY);

    let date = now_in_tz.date();

    // Sort target DOWs by number for earliest-first matching
    let mut sorted_days: Vec<Weekday> = days.to_vec();
    sorted_days.sort_by_key(|d| d.to_jiff().to_monday_one_offset());

    // Find Monday of current week and Monday of anchor week
    let dow_offset = date.weekday().to_monday_one_offset() as i64 - 1;
    let current_monday = date
        .checked_add(jiff::Span::new().days(-dow_offset))
        .map_err(|e| ScheduleError::eval(format!("{e}")))?;

    let anchor_dow_offset = anchor_date.weekday().to_monday_one_offset() as i64 - 1;
    let anchor_monday = anchor_date
        .checked_add(jiff::Span::new().days(-anchor_dow_offset))
        .map_err(|e| ScheduleError::eval(format!("{e}")))?;

    // O(1) alignment: compute the first aligned Monday >= current Monday,
    // then check at most 2 aligned weeks (current aligned week if any
    // target day's time hasn't passed, otherwise the next aligned week).
    let weeks_since_anchor = weeks_between(anchor_monday, current_monday);
    let first_aligned_monday = if weeks_since_anchor < 0 {
        let skip = (-weeks_since_anchor + interval as i64 - 1) / interval as i64;
        current_monday
            .checked_add(jiff::Span::new().days(skip * interval as i64 * 7))
            .map_err(|e| ScheduleError::eval(format!("{e}")))?
    } else {
        let remainder = weeks_since_anchor % (interval as i64);
        if remainder == 0 {
            current_monday
        } else {
            current_monday
                .checked_add(jiff::Span::new().days((interval as i64 - remainder) * 7))
                .map_err(|e| ScheduleError::eval(format!("{e}")))?
        }
    };

    let mut cur_monday = first_aligned_monday;

    for _ in 0..2 {
        // Aligned week — try each target DOW
        for wd in &sorted_days {
            let day_offset = wd.to_jiff().to_monday_one_offset() as i64 - 1;
            let target_date = cur_monday
                .checked_add(jiff::Span::new().days(day_offset))
                .map_err(|e| ScheduleError::eval(format!("{e}")))?;
            if let Some(candidate) = earliest_future_at_times(target_date, times, tz, now)? {
                return Ok(Some(candidate));
            }
        }

        // Advance to next aligned week
        let skip_weeks = interval as i64;
        cur_monday = cur_monday
            .checked_add(jiff::Span::new().days(skip_weeks * 7))
            .map_err(|e| ScheduleError::eval(format!("{e}")))?;
    }

    Ok(None)
}

fn next_month_repeat(
    interval: u32,
    target: &MonthTarget,
    times: &[TimeOfDay],
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());

    let mut year = now_in_tz.date().year();
    let mut month = now_in_tz.date().month();

    let anchor_date = anchor.unwrap_or(*EPOCH_DATE);
    let max_iter = if interval > 1 {
        24 * interval as usize
    } else {
        24
    };

    // Search forward
    for _ in 0..max_iter {
        // Check interval alignment
        if interval > 1 {
            let cur = Date::new(year, month, 1).unwrap();
            let month_offset = months_between_ym(anchor_date, cur);
            if month_offset < 0 || month_offset.rem_euclid(interval as i64) != 0 {
                month += 1;
                if month > 12 {
                    month = 1;
                    year += 1;
                }
                continue;
            }
        }
        let date_candidates = match target {
            MonthTarget::Days(_) => {
                let expanded = target.expand_days();
                let mut c = Vec::new();
                for day_num in expanded {
                    // Skip if this month doesn't have this day
                    let last = last_day_of_month(year, month);
                    if (day_num as i8) <= last.day() {
                        if let Ok(date) = Date::new(year, month, day_num as i8) {
                            c.push(date);
                        }
                    }
                }
                c
            }
            MonthTarget::LastDay => {
                vec![last_day_of_month(year, month)]
            }
            MonthTarget::LastWeekday => {
                vec![last_weekday_of_month(year, month)]
            }
        };

        // For each candidate date, try all times and find the earliest future one
        let mut best: Option<Zoned> = None;
        for date in date_candidates {
            if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                best = Some(match best {
                    Some(prev) if candidate < prev => candidate,
                    Some(prev) => prev,
                    None => candidate,
                });
            }
        }
        if best.is_some() {
            return Ok(best);
        }

        // Next month
        month += 1;
        if month > 12 {
            month = 1;
            year += 1;
        }
    }

    Ok(None)
}

fn next_ordinal_repeat(
    interval: u32,
    ordinal: OrdinalPosition,
    day: Weekday,
    times: &[TimeOfDay],
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());

    let mut year = now_in_tz.date().year();
    let mut month = now_in_tz.date().month();

    let anchor_date = anchor.unwrap_or(*EPOCH_DATE);
    let max_iter = if interval > 1 {
        24 * interval as usize
    } else {
        24
    };

    // Search forward
    for _ in 0..max_iter {
        // Check interval alignment
        if interval > 1 {
            let cur = Date::new(year, month, 1).unwrap();
            let month_offset = months_between_ym(anchor_date, cur);
            if month_offset < 0 || month_offset.rem_euclid(interval as i64) != 0 {
                month += 1;
                if month > 12 {
                    month = 1;
                    year += 1;
                }
                continue;
            }
        }
        let target_date = match ordinal {
            OrdinalPosition::Last => Some(last_weekday_in_month(year, month, day)),
            _ => nth_weekday_of_month(year, month, day, ordinal_to_n(ordinal)),
        };

        if let Some(date) = target_date {
            if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                return Ok(Some(candidate));
            }
        }

        month += 1;
        if month > 12 {
            month = 1;
            year += 1;
        }
    }

    Ok(None)
}

fn next_single_date(
    date_spec: &DateSpec,
    times: &[TimeOfDay],
    tz: &TimeZone,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());

    match date_spec {
        DateSpec::Iso(s) => {
            let date: Date = s
                .parse()
                .map_err(|e| ScheduleError::eval(format!("invalid date '{s}': {e}")))?;
            earliest_future_at_times(date, times, tz, now)
        }
        DateSpec::Named { month, day } => {
            let start_year = now_in_tz.date().year();
            // Try up to 8 years forward (covers leap year cycles)
            for y in 0..8 {
                let year = start_year + y;
                if let Ok(date) = Date::new(year, month.number() as i8, *day as i8) {
                    if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                        return Ok(Some(candidate));
                    }
                }
            }
            Ok(None)
        }
    }
}

fn next_year_repeat(
    interval: u32,
    target: &YearTarget,
    times: &[TimeOfDay],
    tz: &TimeZone,
    anchor: &Option<jiff::civil::Date>,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let now_in_tz = now.with_time_zone(tz.clone());
    let start_year = now_in_tz.date().year();
    let anchor_year = anchor.unwrap_or(*EPOCH_DATE).year();

    let max_iter = if interval > 1 { 8 * interval as i16 } else { 8 };

    for y in 0..max_iter {
        let year = start_year + y;

        // Check interval alignment
        if interval > 1 {
            let year_offset = (year as i64) - (anchor_year as i64);
            if year_offset < 0 || year_offset.rem_euclid(interval as i64) != 0 {
                continue;
            }
        }

        let target_date = match target {
            YearTarget::Date { month, day } => {
                Date::new(year, month.number() as i8, *day as i8).ok()
            }
            YearTarget::OrdinalWeekday {
                ordinal,
                weekday,
                month,
            } => {
                let m = month.number() as i8;
                match ordinal {
                    OrdinalPosition::Last => Some(last_weekday_in_month(year, m, *weekday)),
                    _ => nth_weekday_of_month(year, m, *weekday, ordinal_to_n(*ordinal)),
                }
            }
            YearTarget::DayOfMonth { day, month } => {
                Date::new(year, month.number() as i8, *day as i8).ok()
            }
            YearTarget::LastWeekday { month } => {
                Some(last_weekday_of_month(year, month.number() as i8))
            }
        };

        if let Some(date) = target_date {
            if let Some(candidate) = earliest_future_at_times(date, times, tz, now)? {
                return Ok(Some(candidate));
            }
        }
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn fixed_now() -> Zoned {
        // 2026-02-06T12:00:00 in system tz
        let date = Date::new(2026, 2, 6).unwrap();
        let time = Time::new(12, 0, 0, 0).unwrap();
        date.to_datetime(time).to_zoned(TimeZone::UTC).unwrap()
    }

    #[test]
    fn test_next_every_day() {
        let s = parse("every day at 09:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 2, 7).unwrap());
        assert_eq!(next.time().hour(), 9);
    }

    #[test]
    fn test_next_every_weekday() {
        let s = parse("every weekday at 9:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        // 2026-02-06 is a Friday, time already passed at 12:00
        // Next weekday is Monday 2026-02-09
        assert_eq!(next.date(), Date::new(2026, 2, 9).unwrap());
    }

    #[test]
    fn test_next_weekend() {
        let s = parse("every weekend at 10:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        // 2026-02-07 is Saturday
        assert_eq!(next.date(), Date::new(2026, 2, 7).unwrap());
    }

    #[test]
    fn test_next_interval() {
        let s = parse("every 45 min from 09:00 to 17:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        // At 12:00, next 45-min tick: 9:00+45*4=12:00, but > now means 12:45
        assert_eq!(next.time().hour(), 12);
        assert_eq!(next.time().minute(), 45);
    }

    #[test]
    fn test_next_month_on_day() {
        let s = parse("every month on the 1st at 9:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 3, 1).unwrap());
    }

    #[test]
    fn test_next_month_last_day() {
        let s = parse("every month on the last day at 17:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 2, 28).unwrap());
    }

    #[test]
    fn test_next_ordinal_first_monday() {
        let s = parse("first monday of every month at 10:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        // First Monday of March 2026 = March 2
        assert_eq!(next.date(), Date::new(2026, 3, 2).unwrap());
    }

    #[test]
    fn test_next_single_date_iso() {
        let s = parse("on 2026-03-15 at 14:30 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 3, 15).unwrap());
        assert_eq!(next.time().hour(), 14);
        assert_eq!(next.time().minute(), 30);
    }

    #[test]
    fn test_next_single_date_named() {
        let s = parse("on feb 14 at 9:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 2, 14).unwrap());
    }

    #[test]
    fn test_next_n() {
        let s = parse("every day at 09:00 in UTC").unwrap();
        let now = fixed_now();
        let results = next_n_from(&s, &now, 3).unwrap();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].date(), Date::new(2026, 2, 7).unwrap());
        assert_eq!(results[1].date(), Date::new(2026, 2, 8).unwrap());
        assert_eq!(results[2].date(), Date::new(2026, 2, 9).unwrap());
    }

    #[test]
    fn test_iso_date_in_past() {
        let s = parse("on 2020-01-01 at 00:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap();
        assert!(next.is_none());
    }

    #[test]
    fn test_month_skip_31() {
        // February doesn't have 31 days — should skip to March
        let s = parse("every month on the 31st at 09:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 3, 31).unwrap());
    }

    #[test]
    fn test_next_year_repeat_date() {
        let s = parse("every year on dec 25 at 00:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 12, 25).unwrap());
    }

    #[test]
    fn test_next_year_repeat_ordinal_weekday() {
        let s = parse("every year on the first monday of march at 10:00 in UTC").unwrap();
        let now = fixed_now();
        let next = next_from(&s, &now).unwrap().unwrap();
        assert_eq!(next.date(), Date::new(2026, 3, 2).unwrap());
    }

    #[test]
    fn test_except_skips_holiday() {
        // Every weekday at 09:00, except dec 25 and jan 1
        let s = parse("every weekday at 09:00 except dec 25, jan 1 in UTC").unwrap();
        // Set now to just before Christmas 2026 (dec 24 evening)
        let now = Date::new(2026, 12, 24)
            .unwrap()
            .to_datetime(Time::new(20, 0, 0, 0).unwrap())
            .to_zoned(TimeZone::UTC)
            .unwrap();
        let next = next_from(&s, &now).unwrap().unwrap();
        // Dec 25 is Friday but excepted, so next = Dec 28 (Monday)
        assert_eq!(next.date(), Date::new(2026, 12, 28).unwrap());
    }

    #[test]
    fn test_until_limits_results() {
        let s = parse("every day at 09:00 until 2026-02-10 in UTC").unwrap();
        let now = fixed_now();
        let results = next_n_from(&s, &now, 10).unwrap();
        // Should get Feb 7, 8, 9, 10 (4 results, not 10)
        assert_eq!(results.len(), 4);
        assert_eq!(
            results.last().unwrap().date(),
            Date::new(2026, 2, 10).unwrap()
        );
    }
}
