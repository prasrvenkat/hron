mod calendar;
#[cfg(test)]
mod tests;
mod wall_clock;

use std::sync::LazyLock;

use jiff::civil::{date, Date, Time};
use jiff::tz::TimeZone;
use jiff::{Span, Timestamp, Zoned};

use crate::ast::*;
use calendar::{
    add_days, days_between, first_of_month_index, matches_day_filter, monday_of_week, month_index,
    month_target_dates, months_between, year_target_date,
};
use wall_clock::{civil_time, fixed_time_on, minute_of_day, slot_on, MINUTES_PER_HOUR};

/// Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment").
const EPOCH_MONDAY: Date = date(1970, 1, 5);

const EPOCH_DATE: Date = date(1970, 1, 1);

/// spec/README.md, "Supported range": from RANGE_START inclusive to RANGE_END exclusive.
static RANGE_START: LazyLock<Timestamp> = LazyLock::new(|| "0001-01-02T00:00:00Z".parse().unwrap());
static RANGE_END: LazyLock<Timestamp> = LazyLock::new(|| "9999-12-30T00:00:00Z".parse().unwrap());

/// Slack beyond the horizon for the period one behind the first date's, where a
/// search starts, and for a horizon that starts mid-period.
const HORIZON_MARGIN_PERIODS: i64 = 2;

/// How many dates past its scheduled date a fixed time can land: one shifted out
/// of a gap before midnight lands on the next date. No gap in tzdb exceeds 24 hours.
const MAX_SHIFT_DAYS: i64 = 1;

/// How far now's wall date can trail a date that has begun: one, on the second
/// pass of a fall-back across midnight. No overlap in tzdb exceeds 24 hours.
const MAX_OVERLAP_DAYS: i64 = 1;

/// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
const NAMED_UNTIL_MAX_YEARS: i16 = 8;

pub fn next_from(schedule: &Schedule, now: &Zoned) -> Option<Zoned> {
    search(schedule, now, Direction::Forward)
}

pub fn previous_from(schedule: &Schedule, now: &Zoned) -> Option<Zoned> {
    search(schedule, now, Direction::Backward)
}

fn search(schedule: &Schedule, now: &Zoned, direction: Direction) -> Option<Zoned> {
    if !in_supported_range(now) {
        return None;
    }
    Search::new(schedule).nearest(now, direction)
}

/// Defined through the forward search, so the two can never disagree about what
/// an occurrence is (spec/README.md, "matches is true exactly when the minute
/// containing t is an occurrence").
pub fn matches(schedule: &Schedule, datetime: &Zoned) -> bool {
    if !in_supported_range(datetime) {
        return false;
    }
    let mut search = Search::new(schedule);
    let local = datetime.with_time_zone(search.zone.clone());
    let time = local.time();
    let minute = local
        .checked_sub(
            Span::new()
                .seconds(time.second())
                .nanoseconds(time.subsec_nanosecond()),
        )
        .expect("a supported instant has a day of margin");
    let just_before = minute
        .checked_sub(Span::new().nanoseconds(1))
        .expect("a supported instant has a day of margin");
    // An occurrence never lands before the date it is scheduled on, so one at
    // this minute is scheduled on or before the minute's wall date.
    search.clauses.end_on(minute.date());
    search.nearest(&just_before, Direction::Forward) == Some(minute)
}

pub fn next_n_from(schedule: &Schedule, now: &Zoned, n: usize) -> Vec<Zoned> {
    Occurrences::new(schedule, now.clone()).take(n).collect()
}

pub fn between<'a>(schedule: &'a Schedule, from: &Zoned, to: &Zoned) -> BoundedOccurrences<'a> {
    BoundedOccurrences::new(schedule, from.clone(), to.clone())
}

/// Lazy iterator over schedule occurrences strictly after a given datetime.
pub struct Occurrences<'a> {
    search: Search<'a>,
    current: Option<Zoned>,
}

impl<'a> Occurrences<'a> {
    pub fn new(schedule: &'a Schedule, from: Zoned) -> Self {
        Self {
            search: Search::new(schedule),
            current: Some(from),
        }
    }
}

impl Iterator for Occurrences<'_> {
    type Item = Zoned;

    fn next(&mut self) -> Option<Self::Item> {
        let now = self.current.take().filter(in_supported_range)?;
        let next = self.search.nearest(&now, Direction::Forward)?;
        self.current = Some(next.clone());
        Some(next)
    }
}

/// Bounded iterator for occurrences where from < occurrence <= to.
pub struct BoundedOccurrences<'a> {
    inner: Occurrences<'a>,
    to: Zoned,
}

impl<'a> BoundedOccurrences<'a> {
    pub fn new(schedule: &'a Schedule, from: Zoned, to: Zoned) -> Self {
        Self {
            inner: Occurrences::new(schedule, from),
            to,
        }
    }
}

impl Iterator for BoundedOccurrences<'_> {
    type Item = Zoned;

    fn next(&mut self) -> Option<Self::Item> {
        if !in_supported_range(&self.to) {
            return None;
        }
        self.inner.next().filter(|t| *t <= self.to)
    }
}

#[derive(Clone, Copy)]
enum Direction {
    Forward,
    Backward,
}

impl Direction {
    fn sign(self) -> i64 {
        match self {
            Direction::Forward => 1,
            Direction::Backward => -1,
        }
    }

    fn precedes<T: Ord>(self, a: &T, b: &T) -> bool {
        match self {
            Direction::Forward => a < b,
            Direction::Backward => a > b,
        }
    }
}

struct Search<'a> {
    expr: &'a ScheduleExpr,
    zone: TimeZone,
    cadence: Cadence,
    times: DailyTimes,
    clauses: Clauses,
}

struct Occurrence {
    instant: Zoned,
    landing: Date,
}

impl<'a> Search<'a> {
    fn new(schedule: &'a Schedule) -> Search<'a> {
        Search {
            expr: &schedule.expr,
            zone: resolve_zone(&schedule.timezone),
            cadence: Cadence::of(schedule),
            times: DailyTimes::of(&schedule.expr),
            clauses: Clauses::of(schedule),
        }
    }

    fn nearest(&self, now: &Zoned, direction: Direction) -> Option<Zoned> {
        let now = &now.with_time_zone(self.zone.clone());
        let first_date = self.clauses.clamp(now.date(), direction);
        // A nearest weekday or a DST shift can move an occurrence out of the
        // period it is scheduled in, so the search starts one period back.
        let first_period = self.cadence.period_of(first_date) - direction.sign();
        let reach = self
            .clauses
            .farthest_except_date(direction)
            .map_or(first_period, |date| self.cadence.period_of(date));
        let shift = self.times.max_shift_days();
        let mut best: Option<Occurrence> = None;
        'search: for start in self.cadence.period_starts(first_period, reach, direction) {
            if self.rejects_period(start) {
                continue;
            }
            for candidate in in_order(candidates_in_period(self.expr, start), direction) {
                let beaten = best.as_ref().is_some_and(|best| {
                    !could_beat(candidate.date, best.landing, direction, shift)
                });
                if beaten || self.clauses.ends_search(candidate.date, direction) {
                    break 'search;
                }
                if is_behind(candidate.date, now.date(), direction, shift)
                    || !self.clauses.allows(&candidate)
                {
                    continue;
                }
                let Some(instant) = self.nearest_on_date(candidate.date, now, direction) else {
                    continue;
                };
                if best
                    .as_ref()
                    .is_none_or(|best| direction.precedes(&instant, &best.instant))
                {
                    let landing = instant.date();
                    best = Some(Occurrence { instant, landing });
                }
            }
        }
        best.map(|best| best.instant).filter(in_supported_range)
    }

    /// A day or month period's candidates all target its own month, so one whose
    /// month `during` rejects holds nothing.
    fn rejects_period(&self, start: Date) -> bool {
        matches!(self.cadence.unit, Unit::Day | Unit::Month)
            && !self.clauses.allows_month(start.month())
    }

    fn nearest_on_date(&self, date: Date, now: &Zoned, direction: Direction) -> Option<Zoned> {
        match &self.times {
            // Every time is compared: one shifted out of a gap can land after a
            // later wall time.
            DailyTimes::Fixed(times) => times
                .iter()
                .filter_map(|time| fixed_time_on(date, *time, &self.zone))
                .filter(|t| direction.precedes(now, t))
                .reduce(|nearest, t| {
                    if direction.precedes(&t, &nearest) {
                        t
                    } else {
                        nearest
                    }
                }),
            DailyTimes::Slots(slots) => {
                let now = now.timestamp();
                let slot = |minute: &i64| slot_on(date, *minute, &self.zone);
                match direction {
                    Direction::Forward => {
                        let first = slots.partition_point(|minute| slot(minute).key <= now);
                        slots[first..]
                            .iter()
                            .find_map(|minute| slot(minute).instant)
                    }
                    Direction::Backward => {
                        let end = slots.partition_point(|minute| slot(minute).key < now);
                        slots[..end]
                            .iter()
                            .rev()
                            .find_map(|minute| slot(minute).instant)
                    }
                }
            }
        }
    }
}

fn in_order<T>(mut items: Vec<T>, direction: Direction) -> Vec<T> {
    if let Direction::Backward = direction {
        items.reverse();
    }
    items
}

/// Whether an occurrence scheduled on `date` can precede, in `direction`, the best
/// one, which landed on `landing`. An occurrence lands from its scheduled date to
/// `shift` dates after it, on a first pass, and first passes keep wall-clock order.
fn could_beat(date: Date, landing: Date, direction: Direction, shift: i64) -> bool {
    match direction {
        Direction::Forward => date <= landing,
        Direction::Backward => days_between(date, landing) <= shift,
    }
}

/// True only when every occurrence scheduled on `date` lies behind `now`, whose
/// wall date is `now_date`, in `direction`; false proves nothing.
fn is_behind(date: Date, now_date: Date, direction: Direction, shift: i64) -> bool {
    match direction {
        Direction::Forward => days_between(date, now_date) > shift,
        Direction::Backward => days_between(now_date, date) > MAX_OVERLAP_DAYS,
    }
}

fn in_supported_range(t: &Zoned) -> bool {
    (*RANGE_START..*RANGE_END).contains(&t.timestamp())
}

enum DailyTimes {
    /// Fixed times, each shifted out of a gap.
    Fixed(Vec<Time>),
    /// Interval slots in minutes after midnight, each skipped in a gap.
    Slots(Vec<i64>),
}

impl DailyTimes {
    /// How many dates past its scheduled date an occurrence can land: a gap
    /// pushes a fixed time forward, and skips a slot.
    fn max_shift_days(&self) -> i64 {
        match self {
            DailyTimes::Fixed(_) => MAX_SHIFT_DAYS,
            DailyTimes::Slots(_) => 0,
        }
    }

    fn of(expr: &ScheduleExpr) -> DailyTimes {
        match expr {
            ScheduleExpr::IntervalRepeat {
                interval,
                unit,
                from,
                to,
                ..
            } => DailyTimes::Slots(interval_slots(*interval, *unit, from, to)),
            ScheduleExpr::DayRepeat { times, .. }
            | ScheduleExpr::WeekRepeat { times, .. }
            | ScheduleExpr::MonthRepeat { times, .. }
            | ScheduleExpr::SingleDate { times, .. }
            | ScheduleExpr::YearRepeat { times, .. } => {
                DailyTimes::Fixed(times.iter().map(civil_time).collect())
            }
        }
    }
}

pub(crate) fn interval_slots(
    interval: u32,
    unit: IntervalUnit,
    from: &TimeOfDay,
    to: &TimeOfDay,
) -> Vec<i64> {
    debug_assert!(interval >= 1);
    let interval = interval as i64;
    let step = match unit {
        IntervalUnit::Minutes => interval,
        IntervalUnit::Hours => interval * MINUTES_PER_HOUR,
    };
    let from = minute_of_day(civil_time(from));
    let to = minute_of_day(civil_time(to));
    (0..=(to - from).div_euclid(step))
        .map(|k| from + k * step)
        .collect()
}

/// `during` applies to a candidate's target month; `except`, `until` and
/// `starting` to its date (spec/README.md, "Nearest weekday and `during`",
/// "The `starting` clause").
struct Clauses {
    during: Vec<i8>,
    except_month_days: Vec<(i8, i8)>,
    except_dates: Vec<Date>,
    until: Option<Date>,
    starting: Option<Date>,
}

impl Clauses {
    fn of(schedule: &Schedule) -> Clauses {
        let mut except_month_days = Vec::new();
        let mut except_dates = Vec::new();
        for exception in &schedule.except {
            match exception {
                Exception::Named { month, day } => {
                    except_month_days.push((month.number() as i8, *day as i8))
                }
                Exception::Iso(s) => except_dates.push(iso_date(s)),
            }
        }
        let until = schedule
            .until
            .as_ref()
            .and_then(|until| resolve_until(until, schedule.anchor));
        Clauses {
            during: schedule
                .during
                .iter()
                .map(|month| month.number() as i8)
                .collect(),
            except_month_days,
            except_dates,
            until,
            starting: schedule.anchor,
        }
    }

    fn allows(&self, candidate: &Candidate) -> bool {
        let date = candidate.date;
        self.allows_month(candidate.target_month)
            && !self.except_month_days.contains(&(date.month(), date.day()))
            && !self.except_dates.contains(&date)
            && self.until.is_none_or(|until| date <= until)
            && self.starting.is_none_or(|starting| date >= starting)
    }

    fn allows_month(&self, month: i8) -> bool {
        self.during.is_empty() || self.during.contains(&month)
    }

    fn end_on(&mut self, date: Date) {
        self.until = Some(self.until.map_or(date, |until| until.min(date)));
    }

    /// The one-off except date farthest along `direction`: the calendar repeats
    /// only beyond it (spec/README.md, "Search horizon").
    fn farthest_except_date(&self, direction: Direction) -> Option<Date> {
        match direction {
            Direction::Forward => self.except_dates.iter().max().copied(),
            Direction::Backward => self.except_dates.iter().min().copied(),
        }
    }

    fn clamp(&self, date: Date, direction: Direction) -> Date {
        match direction {
            Direction::Forward => self.starting.map_or(date, |starting| date.max(starting)),
            Direction::Backward => self.until.map_or(date, |until| date.min(until)),
        }
    }

    fn ends_search(&self, date: Date, direction: Direction) -> bool {
        match direction {
            Direction::Forward => self.until.is_some_and(|until| date > until),
            Direction::Backward => self.starting.is_some_and(|starting| date < starting),
        }
    }
}

/// A named until date is the first such date on or after the starting date
/// (spec/README.md, "Named `until`"). None when no such date exists before the
/// calendar ends, so nothing bounds the schedule.
fn resolve_until(until: &UntilSpec, starting: Option<Date>) -> Option<Date> {
    match until {
        UntilSpec::Iso(s) => Some(iso_date(s)),
        UntilSpec::Named { month, day } => {
            let from = starting.expect("a named until always has a starting date");
            (0..=NAMED_UNTIL_MAX_YEARS)
                .filter_map(|k| {
                    let year = from.year().checked_add(k)?;
                    Date::new(year, month.number() as i8, *day as i8).ok()
                })
                .find(|date| *date >= from)
        }
    }
}

fn iso_date(s: &str) -> Date {
    s.parse().expect("an ISO date is always a calendar date")
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

struct Cadence {
    unit: Unit,
    origin: Date,
    interval: i64,
    single: bool,
}

impl Cadence {
    fn of(schedule: &Schedule) -> Cadence {
        let (unit, interval, default_origin) = match &schedule.expr {
            ScheduleExpr::SingleDate {
                date: DateSpec::Iso(s),
                ..
            } => {
                return Cadence {
                    unit: Unit::Day,
                    origin: iso_date(s),
                    interval: 1,
                    single: true,
                };
            }
            ScheduleExpr::SingleDate { .. } => (Unit::Year, 1, EPOCH_DATE),
            ScheduleExpr::IntervalRepeat { .. } => (Unit::Day, 1, EPOCH_DATE),
            ScheduleExpr::DayRepeat { interval, .. } => (Unit::Day, *interval, EPOCH_DATE),
            ScheduleExpr::WeekRepeat { interval, .. } => (Unit::Week, *interval, EPOCH_MONDAY),
            ScheduleExpr::MonthRepeat { interval, .. } => (Unit::Month, *interval, EPOCH_DATE),
            ScheduleExpr::YearRepeat { interval, .. } => (Unit::Year, *interval, EPOCH_DATE),
        };
        let anchor = schedule.anchor.unwrap_or(default_origin);
        let origin = match unit {
            Unit::Day => anchor,
            Unit::Week => monday_of_week(anchor).unwrap_or(anchor),
            Unit::Month => anchor.first_of_month(),
            Unit::Year => anchor.first_of_year(),
        };
        Cadence {
            unit,
            origin,
            interval: interval as i64,
            single: false,
        }
    }

    fn period_of(&self, date: Date) -> i64 {
        match self.unit {
            Unit::Day => days_between(self.origin, date),
            Unit::Week => days_between(self.origin, date).div_euclid(7),
            Unit::Month => months_between(self.origin, date),
            Unit::Year => date.year() as i64 - self.origin.year() as i64,
        }
    }

    fn start_of(&self, k: i64) -> Option<Date> {
        match self.unit {
            Unit::Day => add_days(self.origin, k),
            Unit::Week => add_days(self.origin, k.checked_mul(7)?),
            Unit::Month => first_of_month_index(month_index(self.origin) + k),
            Unit::Year => Date::new(i16::try_from(self.origin.year() as i64 + k).ok()?, 1, 1).ok(),
        }
    }

    /// The first days of the aligned periods from `first_period` in `direction`,
    /// through one search horizon beyond whichever of `first_period` and `reach`
    /// is farther along it (spec/README.md, "Search horizon").
    fn period_starts(
        &self,
        first_period: i64,
        reach: i64,
        direction: Direction,
    ) -> impl Iterator<Item = Date> + '_ {
        let (first, count) = if self.single {
            (0, 1)
        } else {
            let first = self.align(first_period, direction);
            let beyond = direction.sign() * (self.align(reach, direction) - first);
            let count =
                self.horizon_periods() + HORIZON_MARGIN_PERIODS + beyond.max(0) / self.interval;
            (first, count)
        };
        let step = direction.sign() * self.interval;
        // Leading periods past the calendar's edge are skipped, as when the one a
        // search starts from, behind the first date's, lies past its end; after
        // that, the first period past the edge ends the search.
        (0..count)
            .map(move |i| self.start_of(first + i * step))
            .skip_while(Option::is_none)
            .map_while(|start| start)
    }

    fn align(&self, k: i64, direction: Direction) -> i64 {
        match direction {
            Direction::Forward => k + (-k).rem_euclid(self.interval),
            Direction::Backward => k - k.rem_euclid(self.interval),
        }
    }

    /// Aligned periods in lcm(400 years, interval units), after which both the
    /// calendar and the alignment repeat.
    fn horizon_periods(&self) -> i64 {
        let cycle = self.unit.per_400_years();
        cycle / gcd(cycle, self.interval)
    }
}

/// A date the expression fires on, with the month whose day it names. They
/// differ only when a directional nearest weekday crosses into the adjacent month.
struct Candidate {
    date: Date,
    target_month: i8,
}

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
            let fires = day_filter
                .as_ref()
                .is_none_or(|filter| matches_day_filter(start, filter));
            fires.then_some(start).into_iter().collect()
        }
        ScheduleExpr::DayRepeat { days, .. } => matches_day_filter(start, days)
            .then_some(start)
            .into_iter()
            .collect(),
        ScheduleExpr::WeekRepeat { days, .. } => {
            let mut dates: Vec<Date> = days
                .iter()
                .filter_map(|day| add_days(start, day.to_jiff().to_monday_zero_offset() as i64))
                .collect();
            dates.sort();
            dates
        }
        ScheduleExpr::MonthRepeat { target, .. } => {
            month_target_dates(start.year(), start.month(), target)
        }
        ScheduleExpr::YearRepeat { target, .. } => {
            year_target_date(start.year(), target).into_iter().collect()
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

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 {
        a
    } else {
        gcd(b, a % b)
    }
}

fn resolve_zone(name: &Option<String>) -> TimeZone {
    match name {
        Some(name) => TimeZone::get(name).expect("a schedule's timezone is always in the database"),
        None => TimeZone::UTC,
    }
}
