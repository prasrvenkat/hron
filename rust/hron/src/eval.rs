use std::sync::LazyLock;

use jiff::civil::{Date, Time};
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::{Span, Zoned};

use crate::ast::*;
use crate::error::ScheduleError;

/// Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment").
static EPOCH_MONDAY: LazyLock<Date> = LazyLock::new(|| Date::new(1970, 1, 5).unwrap());

/// Default anchor for day, month and year intervals.
static EPOCH_DATE: LazyLock<Date> = LazyLock::new(|| Date::new(1970, 1, 1).unwrap());

fn resolve_tz(tz: &Option<String>) -> Result<TimeZone, ScheduleError> {
    match tz {
        Some(name) => TimeZone::get(name)
            .map_err(|e| ScheduleError::eval(format!("invalid timezone '{name}': {e}"))),
        None => Ok(TimeZone::UTC),
    }
}

fn to_time(tod: &TimeOfDay) -> Time {
    Time::new(tod.hour as i8, tod.minute as i8, 0, 0).unwrap()
}

fn eval_error(e: jiff::Error) -> ScheduleError {
    ScheduleError::eval(format!("cannot create zoned datetime: {e}"))
}

/// jiff's "compatible" disambiguation matches spec/README.md "DST spring-forward
/// (gaps)" and "DST fall-back (ambiguous times)": a gap time shifts forward by the
/// gap length, and a time repeated by a fall-back transition takes its first occurrence.
fn at_time_on_date(date: Date, time: Time, tz: &TimeZone) -> Result<Zoned, ScheduleError> {
    date.to_datetime(time)
        .to_zoned(tz.clone())
        .map_err(eval_error)
}

/// An interval slot whose wall time falls in a spring-forward gap does not exist
/// (spec/README.md, "Interval slots in a spring-forward gap").
fn interval_slot_on_date(
    date: Date,
    minute_of_day: i64,
    tz: &TimeZone,
) -> Result<Option<Zoned>, ScheduleError> {
    let time = Time::new((minute_of_day / 60) as i8, (minute_of_day % 60) as i8, 0, 0).unwrap();
    let ambiguous = tz.to_ambiguous_zoned(date.to_datetime(time));
    if matches!(ambiguous.offset(), AmbiguousOffset::Gap { .. }) {
        return Ok(None);
    }
    ambiguous.earlier().map(Some).map_err(eval_error)
}

fn add_days(date: Date, days: i64) -> Option<Date> {
    date.checked_add(Span::new().try_days(days).ok()?).ok()
}

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

fn last_day_of_month(year: i16, month: i8) -> Date {
    if month == 12 {
        // December always has 31 days; avoids year+1 overflow at i16::MAX
        Date::new(year, 12, 31).unwrap()
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
    let first = Date::new(year, month, 1).ok()?;
    let mut d = first;
    while d.weekday() != target_wd {
        d = d.tomorrow().ok()?;
    }
    for _ in 1..n {
        d = add_days(d, 7)?;
    }
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

fn ordinal_weekday_of_month(
    year: i16,
    month: i8,
    ordinal: OrdinalPosition,
    weekday: Weekday,
) -> Option<Date> {
    match ordinal {
        OrdinalPosition::Last => Some(last_weekday_in_month(year, month, weekday)),
        OrdinalPosition::First => nth_weekday_of_month(year, month, weekday, 1),
        OrdinalPosition::Second => nth_weekday_of_month(year, month, weekday, 2),
        OrdinalPosition::Third => nth_weekday_of_month(year, month, weekday, 3),
        OrdinalPosition::Fourth => nth_weekday_of_month(year, month, weekday, 4),
        OrdinalPosition::Fifth => nth_weekday_of_month(year, month, weekday, 5),
    }
}

/// Get the nearest weekday to a given day in a month.
/// - direction=None: standard cron W behavior (never crosses month boundary)
///
/// Returns None if the target_day doesn't exist in the month (e.g., day 31 in February).
fn nearest_weekday(
    year: i16,
    month: i8,
    target_day: u8,
    direction: Option<NearestDirection>,
) -> Option<Date> {
    let last = last_day_of_month(year, month);
    let last_day = last.day() as u8;

    if target_day > last_day {
        return None;
    }

    let date = Date::new(year, month, target_day as i8).ok()?;
    let wd = date.weekday();

    use jiff::civil::Weekday as JiffWd;

    match (wd, direction) {
        (
            JiffWd::Monday
            | JiffWd::Tuesday
            | JiffWd::Wednesday
            | JiffWd::Thursday
            | JiffWd::Friday,
            _,
        ) => Some(date),

        (JiffWd::Saturday, None) => {
            // Standard: prefer Friday, but if at month start, use Monday
            if target_day == 1 {
                add_days(date, 2)
            } else {
                date.yesterday().ok()
            }
        }
        (JiffWd::Saturday, Some(NearestDirection::Next)) => add_days(date, 2),
        (JiffWd::Saturday, Some(NearestDirection::Previous)) => {
            // Crosses into the previous month when the target is the 1st.
            date.yesterday().ok()
        }

        (JiffWd::Sunday, None) => {
            // Standard: prefer Monday, but if at month end, use Friday
            if target_day >= last_day {
                add_days(date, -2)
            } else {
                date.tomorrow().ok()
            }
        }
        (JiffWd::Sunday, Some(NearestDirection::Next)) => {
            // Crosses into the next month when the target is the last day.
            date.tomorrow().ok()
        }
        (JiffWd::Sunday, Some(NearestDirection::Previous)) => add_days(date, -2),
    }
}

fn days_between(a: Date, b: Date) -> i64 {
    a.until(b).unwrap().get_days() as i64
}

fn months_between_ym(a: Date, b: Date) -> i64 {
    (b.year() as i64 * 12 + b.month() as i64) - (a.year() as i64 * 12 + a.month() as i64)
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
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

fn resolve_until(until: &UntilSpec, now: &Zoned) -> Result<Date, ScheduleError> {
    match until {
        UntilSpec::Iso(s) => s
            .parse()
            .map_err(|e| ScheduleError::eval(format!("invalid until date '{s}': {e}"))),
        UntilSpec::Named { month, day } => {
            let year = now.date().year();
            for y in [year, year + 1] {
                if let Ok(d) = Date::new(y, month.number() as i8, *day as i8) {
                    if d >= now.date() {
                        return Ok(d);
                    }
                }
            }
            Date::new(year + 1, month.number() as i8, *day as i8)
                .map_err(|e| ScheduleError::eval(format!("invalid until date: {e}")))
        }
    }
}

#[derive(Clone, Copy)]
enum Unit {
    Day,
    Week,
    Month,
    Year,
}

impl Unit {
    /// Units in 400 years, after which the proleptic Gregorian calendar repeats.
    fn per_400_years(self) -> i64 {
        match self {
            Unit::Day => 146_097,
            Unit::Week => 20_871,
            Unit::Month => 4_800,
            Unit::Year => 400,
        }
    }
}

/// The periods (days, weeks, months or years) an expression fires in, numbered
/// from `origin`: period `k` is aligned when `k` is a multiple of `interval`.
struct Cadence {
    unit: Unit,
    origin: Date,
    interval: i64,
    /// A single ISO date has one period, the one holding that date.
    single: bool,
    /// A `starting` date admits no interval period before its own.
    from_origin_only: bool,
}

impl Cadence {
    fn of(schedule: &Schedule) -> Result<Cadence, ScheduleError> {
        let (unit, interval, default_origin) = match &schedule.expr {
            ScheduleExpr::SingleDate {
                date: DateSpec::Iso(s),
                ..
            } => {
                let date: Date = s
                    .parse()
                    .map_err(|e| ScheduleError::eval(format!("invalid date '{s}': {e}")))?;
                return Ok(Cadence {
                    unit: Unit::Day,
                    origin: date,
                    interval: 1,
                    single: true,
                    from_origin_only: false,
                });
            }
            ScheduleExpr::SingleDate { .. } => (Unit::Year, 1, *EPOCH_DATE),
            ScheduleExpr::IntervalRepeat { .. } => (Unit::Day, 1, *EPOCH_DATE),
            ScheduleExpr::DayRepeat { interval, .. } => (Unit::Day, *interval, *EPOCH_DATE),
            ScheduleExpr::WeekRepeat { interval, .. } => (Unit::Week, *interval, *EPOCH_MONDAY),
            ScheduleExpr::MonthRepeat { interval, .. } => (Unit::Month, *interval, *EPOCH_DATE),
            ScheduleExpr::YearRepeat { interval, .. } => (Unit::Year, *interval, *EPOCH_DATE),
        };
        let anchor = schedule.anchor.unwrap_or(default_origin);
        let origin = match unit {
            Unit::Day => anchor,
            Unit::Week => {
                let since_monday = anchor.weekday().to_monday_zero_offset() as i64;
                add_days(anchor, -since_monday).unwrap_or(anchor)
            }
            Unit::Month => anchor.first_of_month(),
            Unit::Year => anchor.first_of_year(),
        };
        let interval = (interval as i64).max(1);
        Ok(Cadence {
            unit,
            origin,
            interval,
            single: false,
            from_origin_only: schedule.anchor.is_some() && interval > 1,
        })
    }

    fn period_of(&self, date: Date) -> i64 {
        match self.unit {
            Unit::Day => days_between(self.origin, date),
            Unit::Week => days_between(self.origin, date).div_euclid(7),
            Unit::Month => months_between_ym(self.origin, date),
            Unit::Year => date.year() as i64 - self.origin.year() as i64,
        }
    }

    /// First day of period `k`, or None when it is outside the supported calendar.
    fn start_of(&self, k: i64) -> Option<Date> {
        match self.unit {
            Unit::Day => add_days(self.origin, k),
            Unit::Week => add_days(self.origin, k.checked_mul(7)?),
            Unit::Month => {
                let months = self.origin.year() as i64 * 12 + self.origin.month() as i64 - 1 + k;
                let year = i16::try_from(months.div_euclid(12)).ok()?;
                Date::new(year, months.rem_euclid(12) as i8 + 1, 1).ok()
            }
            Unit::Year => {
                let year = i16::try_from(self.origin.year() as i64 + k).ok()?;
                Date::new(year, 1, 1).ok()
            }
        }
    }

    /// Aligned periods from period `from` in search order, covering the whole
    /// search horizon (spec/README.md, "Search horizon").
    fn aligned_periods(&self, from: i64, forward: bool) -> impl Iterator<Item = i64> {
        let n = self.interval;
        let cycle = self.unit.per_400_years();
        // lcm(cycle, n) / n aligned periods span the horizon from now's period; two
        // more cover the extra period searches start from and the span's far end.
        let horizon = cycle / gcd(cycle, n) + 2;
        let (first, step, count) = if self.single {
            (0, 1, 1)
        } else if forward {
            let first = from + (-from).rem_euclid(n);
            let first = if self.from_origin_only {
                first.max(0)
            } else {
                first
            };
            (first, n, horizon)
        } else {
            (from - from.rem_euclid(n), -n, horizon)
        };
        let from_origin_only = self.from_origin_only;
        (0..count)
            .map(move |i| first + i * step)
            .take_while(move |k| !from_origin_only || *k >= 0)
    }
}

/// A date the expression fires on, with the month whose day it names. They
/// differ only when a directional nearest weekday crosses into the adjacent month.
struct Candidate {
    date: Date,
    target_month: i8,
}

/// The candidates in the period starting at `start`, earliest first.
fn candidates_in_period(expr: &ScheduleExpr, start: Date) -> Vec<Candidate> {
    let target_month = |date: Date| match expr {
        ScheduleExpr::MonthRepeat { .. } => start.month(),
        _ => date.month(),
    };
    dates_in_period(expr, start)
        .into_iter()
        .map(|date| Candidate {
            date,
            target_month: target_month(date),
        })
        .collect()
}

fn dates_in_period(expr: &ScheduleExpr, start: Date) -> Vec<Date> {
    match expr {
        ScheduleExpr::IntervalRepeat { day_filter, .. } => {
            if day_filter
                .as_ref()
                .is_none_or(|filter| matches_day_filter(start, filter))
            {
                vec![start]
            } else {
                vec![]
            }
        }
        ScheduleExpr::DayRepeat { days, .. } => {
            if matches_day_filter(start, days) {
                vec![start]
            } else {
                vec![]
            }
        }
        ScheduleExpr::WeekRepeat { days, .. } => {
            let mut offsets: Vec<i64> = days
                .iter()
                .map(|d| d.to_jiff().to_monday_zero_offset() as i64)
                .collect();
            offsets.sort();
            offsets.dedup();
            offsets
                .into_iter()
                .filter_map(|offset| add_days(start, offset))
                .collect()
        }
        ScheduleExpr::MonthRepeat { target, .. } => {
            let (year, month) = (start.year(), start.month());
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
                    ordinal_weekday_of_month(year, month, *ordinal, *weekday)
                        .into_iter()
                        .collect()
                }
            };
            dates.sort();
            dates.dedup();
            dates
        }
        ScheduleExpr::YearRepeat { target, .. } => {
            let year = start.year();
            let date = match target {
                YearTarget::Date { month, day } | YearTarget::DayOfMonth { day, month } => {
                    Date::new(year, month.number() as i8, *day as i8).ok()
                }
                YearTarget::OrdinalWeekday {
                    ordinal,
                    weekday,
                    month,
                } => ordinal_weekday_of_month(year, month.number() as i8, *ordinal, *weekday),
                YearTarget::LastWeekday { month } => {
                    Some(last_weekday_of_month(year, month.number() as i8))
                }
            };
            date.into_iter().collect()
        }
        ScheduleExpr::SingleDate {
            date: DateSpec::Named { month, day },
            ..
        } => Date::new(start.year(), month.number() as i8, *day as i8)
            .into_iter()
            .collect(),
        ScheduleExpr::SingleDate {
            date: DateSpec::Iso(_),
            ..
        } => vec![start],
    }
}

fn fixed_times(expr: &ScheduleExpr) -> &[TimeOfDay] {
    match expr {
        ScheduleExpr::DayRepeat { times, .. }
        | ScheduleExpr::WeekRepeat { times, .. }
        | ScheduleExpr::MonthRepeat { times, .. }
        | ScheduleExpr::SingleDate { times, .. }
        | ScheduleExpr::YearRepeat { times, .. } => times,
        ScheduleExpr::IntervalRepeat { .. } => &[],
    }
}

/// The fixed-time occurrences on `date`, in instant order: a time shifted out of a
/// DST gap can land after a later wall time.
fn fixed_occurrences(
    expr: &ScheduleExpr,
    date: Date,
    tz: &TimeZone,
) -> Result<Vec<Zoned>, ScheduleError> {
    let mut all = fixed_times(expr)
        .iter()
        .map(|tod| at_time_on_date(date, to_time(tod), tz))
        .collect::<Result<Vec<_>, _>>()?;
    all.sort();
    Ok(all)
}

/// Wall-clock minutes of the slots `from + k × interval` up to and including `to`.
fn interval_slots(interval: u32, unit: IntervalUnit, from: &TimeOfDay, to: &TimeOfDay) -> Vec<i64> {
    let step = match unit {
        IntervalUnit::Minutes => interval as i64,
        IntervalUnit::Hours => interval as i64 * 60,
    }
    .max(1);
    let from = from.hour as i64 * 60 + from.minute as i64;
    let to = to.hour as i64 * 60 + to.minute as i64;
    (from..=to).step_by(step as usize).collect()
}

fn minute_of_day(time: Time) -> i64 {
    time.hour() as i64 * 60 + time.minute() as i64
}

/// The earliest occurrence on `date` strictly after `now`.
fn first_on_date_after(
    expr: &ScheduleExpr,
    date: Date,
    tz: &TimeZone,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let ScheduleExpr::IntervalRepeat {
        interval,
        unit,
        from,
        to,
        ..
    } = expr
    else {
        return Ok(fixed_occurrences(expr, date, tz)?
            .into_iter()
            .find(|t| t > now));
    };
    // Slots resolve in wall-clock order, and a slot whose wall time is before
    // now's has already passed, so the scan can start at now's wall time.
    let now_local = now.with_time_zone(tz.clone());
    let earliest_minute = match date.cmp(&now_local.date()) {
        std::cmp::Ordering::Less => return Ok(None),
        std::cmp::Ordering::Equal => minute_of_day(now_local.time()),
        std::cmp::Ordering::Greater => 0,
    };
    for minute in interval_slots(*interval, *unit, from, to) {
        if minute < earliest_minute {
            continue;
        }
        if let Some(t) = interval_slot_on_date(date, minute, tz)? {
            if t > *now {
                return Ok(Some(t));
            }
        }
    }
    Ok(None)
}

/// The latest occurrence on `date` strictly before `now`.
fn last_on_date_before(
    expr: &ScheduleExpr,
    date: Date,
    tz: &TimeZone,
    now: &Zoned,
) -> Result<Option<Zoned>, ScheduleError> {
    let ScheduleExpr::IntervalRepeat {
        interval,
        unit,
        from,
        to,
        ..
    } = expr
    else {
        return Ok(fixed_occurrences(expr, date, tz)?
            .into_iter()
            .rev()
            .find(|t| t < now));
    };
    if date > now.with_time_zone(tz.clone()).date() {
        return Ok(None);
    }
    // Scans every slot: inside a fall-back overlap, a slot with a later wall time
    // than now's can still be earlier than now.
    for minute in interval_slots(*interval, *unit, from, to).into_iter().rev() {
        if let Some(t) = interval_slot_on_date(date, minute, tz)? {
            if t < *now {
                return Ok(Some(t));
            }
        }
    }
    Ok(None)
}

/// What a search needs besides the expression: time zone, cadence and the
/// trailing clauses resolved once.
struct Search<'a> {
    expr: &'a ScheduleExpr,
    tz: TimeZone,
    cadence: Cadence,
    exceptions: ParsedExceptions,
    during: &'a [MonthName],
    until: Option<Date>,
    starting: Option<Date>,
}

impl<'a> Search<'a> {
    fn new(schedule: &'a Schedule, now: &Zoned) -> Result<Search<'a>, ScheduleError> {
        Ok(Search {
            expr: &schedule.expr,
            tz: resolve_tz(&schedule.timezone)?,
            cadence: Cadence::of(schedule)?,
            exceptions: ParsedExceptions::from_exceptions(&schedule.except),
            during: &schedule.during,
            until: match &schedule.until {
                Some(until) => Some(resolve_until(until, now)?),
                None => None,
            },
            starting: schedule.anchor,
        })
    }

    /// `during` applies to the target month; `except` to the date the occurrence
    /// lands on (spec/README.md, "Nearest weekday and `during`").
    fn allows(&self, candidate: &Candidate) -> bool {
        let in_during = self.during.is_empty()
            || self
                .during
                .iter()
                .any(|m| m.number() as i8 == candidate.target_month);
        in_during && !self.exceptions.is_excepted(candidate.date)
    }

    fn local_date(&self, t: &Zoned) -> Date {
        t.with_time_zone(self.tz.clone()).date()
    }
}

// A fixed time shifted out of a gap before midnight lands on the next date, so
// the candidate after a result can still hold an earlier (or later, searching
// back) instant. The searches keep the best result until candidates move past
// the date it lands on.

pub fn next_from(schedule: &Schedule, now: &Zoned) -> Result<Option<Zoned>, ScheduleError> {
    let search = Search::new(schedule, now)?;
    let cadence = &search.cadence;
    // One period back: a directional nearest weekday can land in the next month.
    let from = cadence.period_of(search.local_date(now)) - 1;
    let mut best: Option<Zoned> = None;
    for k in cadence.aligned_periods(from, true) {
        let Some(start) = cadence.start_of(k) else {
            continue;
        };
        for candidate in candidates_in_period(search.expr, start) {
            if best
                .as_ref()
                .is_some_and(|b| candidate.date > search.local_date(b))
                || search.until.is_some_and(|until| candidate.date > until)
            {
                return Ok(best);
            }
            if !search.allows(&candidate) {
                continue;
            }
            if let Some(t) = first_on_date_after(search.expr, candidate.date, &search.tz, now)? {
                if best.as_ref().is_none_or(|b| t < *b) {
                    best = Some(t);
                }
            }
        }
    }
    Ok(best)
}

pub fn previous_from(schedule: &Schedule, now: &Zoned) -> Result<Option<Zoned>, ScheduleError> {
    let search = Search::new(schedule, now)?;
    let cadence = &search.cadence;
    let now_date = search.local_date(now);
    // Nothing fires after `until`, so a search from far past it starts there.
    let latest_date = search.until.map_or(now_date, |until| until.min(now_date));
    // One period ahead: a directional nearest weekday can land in the previous month.
    let from = cadence.period_of(latest_date) + 1;
    let mut best: Option<Zoned> = None;
    for k in cadence.aligned_periods(from, false) {
        let Some(start) = cadence.start_of(k) else {
            continue;
        };
        for candidate in candidates_in_period(search.expr, start).into_iter().rev() {
            let cannot_reach_best = best.as_ref().is_some_and(|b| {
                add_days(candidate.date, 1).is_some_and(|d| d < search.local_date(b))
            });
            let before_starting = search
                .starting
                .is_some_and(|starting| candidate.date < starting);
            if cannot_reach_best || before_starting {
                return Ok(best);
            }
            if search.until.is_some_and(|until| candidate.date > until)
                || !search.allows(&candidate)
            {
                continue;
            }
            if let Some(t) = last_on_date_before(search.expr, candidate.date, &search.tz, now)? {
                if best.as_ref().is_none_or(|b| t > *b) {
                    best = Some(t);
                }
            }
        }
    }
    Ok(best)
}

/// Defined through `next_from`, so the two can never disagree about what an
/// occurrence is (spec/README.md, "matches is true exactly when the minute
/// containing t is an occurrence").
pub fn matches(schedule: &Schedule, datetime: &Zoned) -> Result<bool, ScheduleError> {
    let time = datetime.time();
    let minute_start = datetime
        .checked_sub(
            Span::new()
                .seconds(time.second())
                .nanoseconds(time.subsec_nanosecond()),
        )
        .map_err(eval_error)?;
    let just_before = minute_start
        .checked_sub(Span::new().nanoseconds(1))
        .map_err(eval_error)?;
    Ok(next_from(schedule, &just_before)? == Some(minute_start))
}

pub fn next_n_from(
    schedule: &Schedule,
    now: &Zoned,
    n: usize,
) -> Result<Vec<Zoned>, ScheduleError> {
    Occurrences::new(schedule, now.clone()).take(n).collect()
}

/// Lazy iterator over schedule occurrences strictly after a given datetime.
pub struct Occurrences<'a> {
    schedule: &'a Schedule,
    current: Zoned,
}

impl<'a> Occurrences<'a> {
    /// Create a new iterator over occurrences strictly after `from`.
    pub fn new(schedule: &'a Schedule, from: Zoned) -> Self {
        Self {
            schedule,
            current: from,
        }
    }
}

impl Iterator for Occurrences<'_> {
    type Item = Result<Zoned, ScheduleError>;

    fn next(&mut self) -> Option<Self::Item> {
        match next_from(self.schedule, &self.current) {
            Ok(Some(dt)) => {
                self.current = dt.clone();
                Some(Ok(dt))
            }
            Ok(None) => None,
            Err(e) => Some(Err(e)),
        }
    }
}

/// Bounded iterator for occurrences where from < occurrence <= to.
pub struct BoundedOccurrences<'a> {
    inner: Occurrences<'a>,
    to: Zoned,
}

impl<'a> BoundedOccurrences<'a> {
    /// Create a new bounded iterator for occurrences in the range (from, to].
    pub fn new(schedule: &'a Schedule, from: Zoned, to: Zoned) -> Self {
        Self {
            inner: Occurrences::new(schedule, from),
            to,
        }
    }
}

impl Iterator for BoundedOccurrences<'_> {
    type Item = Result<Zoned, ScheduleError>;

    fn next(&mut self) -> Option<Self::Item> {
        match self.inner.next() {
            Some(Ok(dt)) if dt <= self.to => Some(Ok(dt)),
            Some(Ok(_)) => None, // Past end bound
            Some(Err(e)) => Some(Err(e)),
            None => None,
        }
    }
}

pub fn between<'a>(schedule: &'a Schedule, from: &Zoned, to: &Zoned) -> BoundedOccurrences<'a> {
    BoundedOccurrences::new(schedule, from.clone(), to.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn fixed_now() -> Zoned {
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
        let s = parse("every month on the first monday at 10:00 in UTC").unwrap();
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
        let s = parse("every weekday at 09:00 except dec 25, jan 1 in UTC").unwrap();
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
