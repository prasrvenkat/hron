use crate::ast::*;
use crate::error::ScheduleError;
use crate::eval::interval_slots;

const MAX_LISTED_TIMES: usize = 24;
const BOTH_DAYS_RESTRICTED: &str =
    "not expressible in hron: cron fires on either the day of month or the day of week";
const INTERVAL_DAYS: &str =
    "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";
const MINUTES_PER_DAY: u32 = 24 * 60;
const MIDNIGHT: TimeOfDay = TimeOfDay { hour: 0, minute: 0 };
const END_OF_DAY: TimeOfDay = TimeOfDay {
    hour: 23,
    minute: 59,
};

// Digit strings may be of any length. Every number at or above this cap is out
// of every field's range and steps past every range's end, so saturating at it
// keeps each comparison exact without overflow.
const NUMBER_CAP: u32 = 1000;

const MONTH_NAMES: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const DAY_NAMES: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
const MONTHS: [MonthName; 12] = [
    MonthName::January,
    MonthName::February,
    MonthName::March,
    MonthName::April,
    MonthName::May,
    MonthName::June,
    MonthName::July,
    MonthName::August,
    MonthName::September,
    MonthName::October,
    MonthName::November,
    MonthName::December,
];
const WEEKDAYS: [Weekday; 7] = [
    Weekday::Sunday,
    Weekday::Monday,
    Weekday::Tuesday,
    Weekday::Wednesday,
    Weekday::Thursday,
    Weekday::Friday,
    Weekday::Saturday,
];
const ORDINALS: [OrdinalPosition; 5] = [
    OrdinalPosition::First,
    OrdinalPosition::Second,
    OrdinalPosition::Third,
    OrdinalPosition::Fourth,
    OrdinalPosition::Fifth,
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Field {
    Minute,
    Hour,
    DayOfMonth,
    Month,
    DayOfWeek,
}

impl Field {
    fn name(self) -> &'static str {
        match self {
            Field::Minute => "minute",
            Field::Hour => "hour",
            Field::DayOfMonth => "day of month",
            Field::Month => "month",
            Field::DayOfWeek => "day of week",
        }
    }

    fn min(self) -> u32 {
        match self {
            Field::Minute | Field::Hour | Field::DayOfWeek => 0,
            Field::DayOfMonth | Field::Month => 1,
        }
    }

    fn max(self) -> u32 {
        match self {
            Field::Minute => 59,
            Field::Hour => 23,
            Field::DayOfMonth => 31,
            Field::Month => 12,
            Field::DayOfWeek => 7,
        }
    }

    // In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
    fn star_end(self) -> u32 {
        match self {
            Field::DayOfWeek => 6,
            _ => self.max(),
        }
    }

    fn names(self) -> &'static [&'static str] {
        match self {
            Field::Month => &MONTH_NAMES,
            Field::DayOfWeek => &DAY_NAMES,
            _ => &[],
        }
    }
}

enum Bounds<'a> {
    Star,
    Value(&'a str),
    Range(&'a str, &'a str),
}

struct Item<'a> {
    bounds: Bounds<'a>,
    step: Option<&'a str>,
}

enum MonthDays {
    Any,
    Days(Vec<u8>),
    Last,
    LastWeekday,
    Nearest(u8),
}

enum WeekDays {
    Any,
    Days(Vec<u8>),
    Nth(Weekday, u8),
    Last(Weekday),
}

enum Days {
    OfWeek(DayFilter),
    OfMonth(MonthTarget),
}

pub fn from_cron(input: &str) -> Result<Schedule, ScheduleError> {
    let input = input.trim_matches([' ', '\t', '\r', '\n']);
    let text = if input.starts_with('@') {
        shortcut(input)?
    } else {
        input
    };
    let fields: Vec<&str> = text.split([' ', '\t']).filter(|f| !f.is_empty()).collect();
    let [minute, hour, day_of_month, month, day_of_week] = fields[..] else {
        return Err(ScheduleError::cron(format!(
            "expected 5 cron fields, got {}",
            fields.len()
        )));
    };

    let minutes = sorted(values(minute, Field::Minute)?);
    let hours = sorted(values(hour, Field::Hour)?);
    let month_days = parse_day_of_month(day_of_month)?;
    let months = sorted(values(month, Field::Month)?);
    let week_days = parse_day_of_week(day_of_week)?;
    let days = day_expression(month_days, week_days)?;
    let times: Vec<TimeOfDay> = hours
        .iter()
        .flat_map(|&hour| {
            minutes
                .iter()
                .map(move |&minute| TimeOfDay { hour, minute })
        })
        .collect();

    let gap = equal_gap(&times);
    let expr = if let (Days::OfWeek(filter), Some(gap)) = (&days, gap) {
        interval(&times, gap, filter.clone())
    } else if times.len() > MAX_LISTED_TIMES {
        return Err(too_many_times(times.len(), gap));
    } else if let Some(target) = year_target(&days, &months) {
        ScheduleExpr::YearRepeat {
            interval: 1,
            target,
            times,
        }
    } else {
        match days {
            Days::OfWeek(days) => ScheduleExpr::DayRepeat {
                interval: 1,
                days,
                times,
            },
            Days::OfMonth(target) => ScheduleExpr::MonthRepeat {
                interval: 1,
                target,
                times,
            },
        }
    };
    let yearly = matches!(expr, ScheduleExpr::YearRepeat { .. });
    let during = if !yearly && months.len() < MONTHS.len() {
        months.iter().map(|&m| MONTHS[m as usize - 1]).collect()
    } else {
        Vec::new()
    };
    Ok(Schedule::from_valid_parts(ScheduleParts {
        expression: expr,
        timezone: None,
        except: Vec::new(),
        until: None,
        starting: None,
        during,
    }))
}

fn shortcut(input: &str) -> Result<&'static str, ScheduleError> {
    match input.to_ascii_lowercase().as_str() {
        "@yearly" | "@annually" => Ok("0 0 1 1 *"),
        "@monthly" => Ok("0 0 1 * *"),
        "@weekly" => Ok("0 0 * * 0"),
        "@daily" | "@midnight" => Ok("0 0 * * *"),
        "@hourly" => Ok("0 * * * *"),
        _ => Err(ScheduleError::cron(format!(
            "unknown cron shortcut: {input}"
        ))),
    }
}

fn parse_day_of_month(text: &str) -> Result<MonthDays, ScheduleError> {
    if text == "*" || text == "?" {
        return Ok(MonthDays::Any);
    }
    if text.eq_ignore_ascii_case("L") {
        return Ok(MonthDays::Last);
    }
    if text.eq_ignore_ascii_case("LW") {
        return Ok(MonthDays::LastWeekday);
    }
    if let Some(day) = text.strip_suffix(['W', 'w']).filter(|day| is_number(day)) {
        return Ok(MonthDays::Nearest(
            field_value(day, Field::DayOfMonth)? as u8
        ));
    }
    Ok(MonthDays::Days(values(text, Field::DayOfMonth)?))
}

fn parse_day_of_week(text: &str) -> Result<WeekDays, ScheduleError> {
    let field = Field::DayOfWeek;
    if text == "*" || text == "?" {
        return Ok(WeekDays::Any);
    }
    if let Some((day, nth)) = text
        .split_once('#')
        .filter(|(day, nth)| is_value(day, field) && is_number(nth))
    {
        let weekday = WEEKDAYS[field_value(day, field)? as usize % 7];
        let n = number(nth);
        if !(1..=5).contains(&n) {
            return Err(ScheduleError::cron(format!(
                "day of week ordinal must be 1-5, got {nth}"
            )));
        }
        return Ok(WeekDays::Nth(weekday, n as u8));
    }
    if let Some(day) = text
        .strip_suffix(['L', 'l'])
        .filter(|day| is_value(day, field))
    {
        return Ok(WeekDays::Last(
            WEEKDAYS[field_value(day, field)? as usize % 7],
        ));
    }
    Ok(WeekDays::Days(values(text, field)?))
}

// Keeps the order of first appearance, in which fromCron lists days of the week.
fn values(text: &str, field: Field) -> Result<Vec<u8>, ScheduleError> {
    let items = items(text, field)
        .ok_or_else(|| ScheduleError::cron(format!("invalid {}: {text}", field.name())))?;
    let mut values = Vec::new();
    for item in items {
        let (first, last) = match item.bounds {
            Bounds::Star => (field.min(), field.star_end()),
            Bounds::Value(a) => {
                let first = field_value(a, field)?;
                let last = match item.step {
                    // `7/n` starts past the end of `*`, so it is Sunday alone.
                    Some(_) => first.max(field.star_end()),
                    None => first,
                };
                (first, last)
            }
            Bounds::Range(a, b) => {
                let (first, last) = (field_value(a, field)?, field_value(b, field)?);
                if first > last {
                    return Err(ScheduleError::cron(format!(
                        "{} range must not run backwards: {a}-{b}",
                        field.name()
                    )));
                }
                (first, last)
            }
        };
        let step = item.step.map_or(1, number);
        if step == 0 {
            return Err(ScheduleError::cron(format!(
                "{} step must be at least 1",
                field.name()
            )));
        }
        for value in (first..=last).step_by(step as usize) {
            let value = (if field == Field::DayOfWeek {
                value % 7
            } else {
                value
            }) as u8;
            if !values.contains(&value) {
                values.push(value);
            }
        }
    }
    Ok(values)
}

fn items(text: &str, field: Field) -> Option<Vec<Item<'_>>> {
    text.split(',')
        .map(|item| {
            let (range, step) = match item.split_once('/') {
                Some((range, step)) => (range, Some(step)),
                None => (item, None),
            };
            let bounds = match range.split_once('-') {
                _ if range == "*" => Bounds::Star,
                Some((a, b)) => Bounds::Range(a, b),
                None => Bounds::Value(range),
            };
            let valid = step.is_none_or(is_number)
                && match bounds {
                    Bounds::Star => true,
                    Bounds::Value(a) => is_value(a, field),
                    Bounds::Range(a, b) => is_value(a, field) && is_value(b, field),
                };
            valid.then_some(Item { bounds, step })
        })
        .collect()
}

fn is_number(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())
}

fn is_value(text: &str, field: Field) -> bool {
    is_number(text) || name_value(text, field).is_some()
}

fn name_value(text: &str, field: Field) -> Option<u32> {
    let index = field
        .names()
        .iter()
        .position(|name| name.eq_ignore_ascii_case(text))?;
    Some(index as u32 + field.min())
}

fn number(digits: &str) -> u32 {
    digits.bytes().fold(0, |n, digit| {
        (n * 10 + u32::from(digit - b'0')).min(NUMBER_CAP)
    })
}

fn field_value(text: &str, field: Field) -> Result<u32, ScheduleError> {
    let value = name_value(text, field).unwrap_or_else(|| number(text));
    if value < field.min() || value > field.max() {
        return Err(ScheduleError::cron(format!(
            "{} must be {}-{}, got {text}",
            field.name(),
            field.min(),
            field.max()
        )));
    }
    Ok(value)
}

fn day_expression(month_days: MonthDays, week_days: WeekDays) -> Result<Days, ScheduleError> {
    Ok(match (month_days, week_days) {
        (MonthDays::Any, WeekDays::Any) => Days::OfWeek(DayFilter::Every),
        (MonthDays::Any, WeekDays::Days(days)) => Days::OfWeek(weekday_filter(&days)),
        (MonthDays::Any, WeekDays::Nth(weekday, n)) => Days::OfMonth(MonthTarget::OrdinalWeekday {
            ordinal: ORDINALS[n as usize - 1],
            weekday,
        }),
        (MonthDays::Any, WeekDays::Last(weekday)) => Days::OfMonth(MonthTarget::OrdinalWeekday {
            ordinal: OrdinalPosition::Last,
            weekday,
        }),
        (MonthDays::Days(days), WeekDays::Any) if days.len() == 31 => {
            Days::OfWeek(DayFilter::Every)
        }
        (MonthDays::Days(days), WeekDays::Any) => {
            let specs = runs(&sorted(days))
                .into_iter()
                .map(|(first, last)| {
                    if first == last {
                        DayOfMonthSpec::Single(first)
                    } else {
                        DayOfMonthSpec::Range(first, last)
                    }
                })
                .collect();
            Days::OfMonth(MonthTarget::Days(specs))
        }
        (MonthDays::Last, WeekDays::Any) => Days::OfMonth(MonthTarget::LastDay),
        (MonthDays::LastWeekday, WeekDays::Any) => Days::OfMonth(MonthTarget::LastWeekday),
        (MonthDays::Nearest(day), WeekDays::Any) => Days::OfMonth(MonthTarget::NearestWeekday {
            day,
            direction: None,
        }),
        _ => return Err(ScheduleError::cron(BOTH_DAYS_RESTRICTED)),
    })
}

fn weekday_filter(days: &[u8]) -> DayFilter {
    match sorted(days.to_vec()).as_slice() {
        [0, 1, 2, 3, 4, 5, 6] => DayFilter::Every,
        [1, 2, 3, 4, 5] => DayFilter::Weekday,
        [0, 6] => DayFilter::Weekend,
        _ => DayFilter::Days(days.iter().map(|&d| WEEKDAYS[d as usize]).collect()),
    }
}

fn equal_gap(times: &[TimeOfDay]) -> Option<u32> {
    let minutes: Vec<u32> = times.iter().map(|&t| minute_of_day(t)).collect();
    let gap = minutes.get(1)? - minutes[0];
    let equal = minutes.len() >= 3 && minutes.windows(2).all(|w| w[1] - w[0] == gap);
    equal.then_some(gap)
}

fn interval(times: &[TimeOfDay], gap: u32, days: DayFilter) -> ScheduleExpr {
    let from = times[0];
    let last = times[times.len() - 1];
    let to = if from == MIDNIGHT && minute_of_day(last) + gap >= MINUTES_PER_DAY {
        END_OF_DAY
    } else {
        last
    };
    let (interval, unit) = if gap.is_multiple_of(60) {
        (gap / 60, IntervalUnit::Hours)
    } else {
        (gap, IntervalUnit::Minutes)
    };
    ScheduleExpr::IntervalRepeat {
        interval,
        unit,
        from,
        to,
        day_filter: (days != DayFilter::Every).then_some(days),
    }
}

fn too_many_times(count: usize, gap: Option<u32>) -> ScheduleError {
    match gap {
        Some(_) => ScheduleError::cron(INTERVAL_DAYS),
        None => ScheduleError::cron(format!(
            "not expressible in hron: {count} times a day are too many to list"
        )),
    }
}

fn year_target(days: &Days, months: &[u8]) -> Option<YearTarget> {
    let (Days::OfMonth(target), &[month]) = (days, months) else {
        return None;
    };
    let month = MONTHS[month as usize - 1];
    match target {
        MonthTarget::Days(specs) => match specs.as_slice() {
            [DayOfMonthSpec::Single(day)] if *day <= month.max_day() => {
                Some(YearTarget::Date { month, day: *day })
            }
            _ => None,
        },
        MonthTarget::LastWeekday => Some(YearTarget::LastWeekday { month }),
        MonthTarget::OrdinalWeekday { ordinal, weekday } => Some(YearTarget::OrdinalWeekday {
            ordinal: *ordinal,
            weekday: *weekday,
            month,
        }),
        _ => None,
    }
}

pub fn to_cron(schedule: &Schedule) -> Result<String, ScheduleError> {
    if !schedule.except.is_empty() {
        return Err(not_expressible("except clauses not supported"));
    }
    if schedule.until.is_some() {
        return Err(not_expressible("until clauses not supported"));
    }
    if schedule.starting.is_some() {
        return Err(not_expressible("starting clauses not supported"));
    }
    let (day_of_month, day_of_week) = day_fields(&schedule.expression)?;
    let month = month_field(schedule)?;
    let (minute, hour) = time_fields(&schedule.expression)?;
    Ok(format!(
        "{minute} {hour} {day_of_month} {month} {day_of_week}"
    ))
}

fn not_expressible(reason: &str) -> ScheduleError {
    ScheduleError::cron(format!("not expressible as cron: {reason}"))
}

fn repeats_once(interval: u32, unit: &str) -> Result<(), ScheduleError> {
    if interval > 1 {
        return Err(not_expressible(&format!(
            "multi-{unit} repeats not supported"
        )));
    }
    Ok(())
}

fn day_fields(expr: &ScheduleExpr) -> Result<(String, String), ScheduleError> {
    let any = || "*".to_string();
    match expr {
        ScheduleExpr::IntervalRepeat { day_filter, .. } => {
            Ok((any(), day_filter.as_ref().map_or_else(any, filter_field)))
        }
        ScheduleExpr::DayRepeat { interval, days, .. } => {
            repeats_once(*interval, "day")?;
            Ok((any(), filter_field(days)))
        }
        ScheduleExpr::WeekRepeat { interval, days, .. } => {
            repeats_once(*interval, "week")?;
            Ok((any(), weekdays_field(days)))
        }
        ScheduleExpr::MonthRepeat {
            interval, target, ..
        } => {
            repeats_once(*interval, "month")?;
            match target {
                MonthTarget::Days(_) => {
                    let days = sorted_unique(target.expand_days());
                    Ok((list_field(&days, 31), any()))
                }
                MonthTarget::LastDay => Ok(("L".into(), any())),
                MonthTarget::LastWeekday => Ok(("LW".into(), any())),
                MonthTarget::NearestWeekday {
                    direction: Some(_), ..
                } => Err(not_expressible("directional nearest weekday not supported")),
                MonthTarget::NearestWeekday {
                    day,
                    direction: None,
                } => Ok((format!("{day}W"), any())),
                MonthTarget::OrdinalWeekday { ordinal, weekday } => {
                    Ok((any(), ordinal_field(*ordinal, *weekday)))
                }
            }
        }
        ScheduleExpr::YearRepeat {
            interval, target, ..
        } => {
            repeats_once(*interval, "year")?;
            match target {
                YearTarget::Date { day, .. } | YearTarget::DayOfMonth { day, .. } => {
                    Ok((day.to_string(), any()))
                }
                YearTarget::OrdinalWeekday {
                    ordinal, weekday, ..
                } => Ok((any(), ordinal_field(*ordinal, *weekday))),
                YearTarget::LastWeekday { .. } => Ok(("LW".into(), any())),
            }
        }
        ScheduleExpr::SingleDate {
            date: DateSpec::Iso(_),
            ..
        } => Err(not_expressible("ISO dates do not repeat")),
        ScheduleExpr::SingleDate {
            date: DateSpec::Named { day, .. },
            ..
        } => Ok((day.to_string(), any())),
    }
}

fn month_field(schedule: &Schedule) -> Result<String, ScheduleError> {
    let during = &schedule.during;
    match own_month(&schedule.expression) {
        Some(month) if !during.is_empty() && !during.contains(&month) => {
            Err(not_expressible("during excludes the schedule's month"))
        }
        Some(month) => Ok(month.number().to_string()),
        None if during.is_empty() => Ok("*".into()),
        None => Ok(list_field(
            &sorted_unique(during.iter().map(|m| m.number())),
            12,
        )),
    }
}

fn own_month(expr: &ScheduleExpr) -> Option<MonthName> {
    match expr {
        ScheduleExpr::YearRepeat { target, .. } => Some(match target {
            YearTarget::Date { month, .. }
            | YearTarget::DayOfMonth { month, .. }
            | YearTarget::OrdinalWeekday { month, .. }
            | YearTarget::LastWeekday { month } => *month,
        }),
        ScheduleExpr::SingleDate {
            date: DateSpec::Named { month, .. },
            ..
        } => Some(*month),
        _ => None,
    }
}

fn time_fields(expr: &ScheduleExpr) -> Result<(String, String), ScheduleError> {
    let times = daily_times(expr);
    let minutes = sorted_unique(times.iter().map(|t| (t % 60) as u8));
    let hours = sorted_unique(times.iter().map(|t| (t / 60) as u8));
    if minutes.len() * hours.len() != times.len() {
        return Err(not_expressible(
            "times are not every combination of their minutes and hours",
        ));
    }
    Ok((step_field(&minutes, 60), step_field(&hours, 24)))
}

fn daily_times(expr: &ScheduleExpr) -> Vec<u32> {
    let mut times: Vec<u32> = match expr {
        ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            ..
        } => interval_slots(*interval, *unit, from, to)
            .into_iter()
            .map(|slot| slot as u32)
            .collect(),
        ScheduleExpr::DayRepeat { times, .. }
        | ScheduleExpr::WeekRepeat { times, .. }
        | ScheduleExpr::MonthRepeat { times, .. }
        | ScheduleExpr::YearRepeat { times, .. }
        | ScheduleExpr::SingleDate { times, .. } => {
            times.iter().map(|&t| minute_of_day(t)).collect()
        }
    };
    times.sort_unstable();
    times.dedup();
    times
}

fn filter_field(filter: &DayFilter) -> String {
    match filter {
        DayFilter::Every => "*".into(),
        DayFilter::Weekday => weekdays_field(&Weekday::all_weekdays()),
        DayFilter::Weekend => weekdays_field(&Weekday::all_weekend()),
        DayFilter::Days(days) => weekdays_field(days),
    }
}

fn weekdays_field(days: &[Weekday]) -> String {
    list_field(&sorted_unique(days.iter().map(|&d| cron_day(d))), 7)
}

fn ordinal_field(ordinal: OrdinalPosition, weekday: Weekday) -> String {
    let day = cron_day(weekday);
    match ORDINALS.iter().position(|&o| o == ordinal) {
        Some(index) => format!("{day}#{}", index + 1),
        None => format!("{day}L"),
    }
}

// ISO numbers Sunday 7; cron numbers it 0.
fn cron_day(weekday: Weekday) -> u8 {
    weekday.number() % 7
}

fn step_field(values: &[u8], size: u8) -> String {
    let first = values[0];
    let last = values[values.len() - 1];
    let gap = values.get(1).map(|second| second - first);
    let equal_gaps = gap.is_some_and(|gap| values.windows(2).all(|w| w[1] - w[0] == gap));
    match gap {
        _ if values.len() == size as usize => "*".into(),
        None => first.to_string(),
        Some(gap) if equal_gaps && first == 0 && last + gap == size => format!("*/{gap}"),
        Some(1) if equal_gaps => format!("{first}-{last}"),
        Some(gap) if equal_gaps && values.len() >= 3 => format!("{first}-{last}/{gap}"),
        _ => list_field(values, size),
    }
}

fn list_field(values: &[u8], size: u8) -> String {
    if values.len() == size as usize {
        return "*".into();
    }
    runs(values)
        .iter()
        .map(|&(first, last)| {
            if first == last {
                first.to_string()
            } else {
                format!("{first}-{last}")
            }
        })
        .collect::<Vec<_>>()
        .join(",")
}

fn runs(sorted_values: &[u8]) -> Vec<(u8, u8)> {
    let mut runs: Vec<(u8, u8)> = Vec::new();
    for &value in sorted_values {
        match runs.last_mut() {
            Some((_, last)) if *last + 1 == value => *last = value,
            _ => runs.push((value, value)),
        }
    }
    runs
}

fn minute_of_day(time: TimeOfDay) -> u32 {
    u32::from(time.hour) * 60 + u32::from(time.minute)
}

fn sorted(mut values: Vec<u8>) -> Vec<u8> {
    values.sort_unstable();
    values
}

fn sorted_unique(values: impl IntoIterator<Item = u8>) -> Vec<u8> {
    let mut values: Vec<u8> = values.into_iter().collect();
    values.sort_unstable();
    values.dedup();
    values
}
