use crate::ast::*;
use crate::error::ScheduleError;

/// Convert a Schedule to a 5-field cron expression (minute hour dom month dow).
pub fn to_cron(schedule: &Schedule) -> Result<String, ScheduleError> {
    if !schedule.except.is_empty() {
        return Err(ScheduleError::cron(
            "not expressible as cron (except clauses not supported)",
        ));
    }
    if schedule.until.is_some() {
        return Err(ScheduleError::cron(
            "not expressible as cron (until clauses not supported)",
        ));
    }
    if !schedule.during.is_empty() {
        return Err(ScheduleError::cron(
            "not expressible as cron (during clauses not supported)",
        ));
    }
    match &schedule.expr {
        ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        } => {
            if *interval > 1 {
                return Err(ScheduleError::cron(
                    "not expressible as cron (multi-day intervals not supported)",
                ));
            }
            if times.len() != 1 {
                return Err(ScheduleError::cron(
                    "not expressible as cron (multiple times not supported)",
                ));
            }
            let time = &times[0];
            let dow = day_filter_to_cron_dow(days)?;
            Ok(format!("{} {} * * {}", time.minute, time.hour, dow))
        }

        ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            day_filter,
        } => {
            // Only expressible if window is full day (00:00 to 23:59)
            let full_day = from.hour == 0 && from.minute == 0 && to.hour == 23 && to.minute == 59;
            if !full_day {
                return Err(ScheduleError::cron(
                    "not expressible as cron (partial-day interval windows not supported)",
                ));
            }
            if day_filter.is_some() {
                return Err(ScheduleError::cron(
                    "not expressible as cron (interval with day filter not supported)",
                ));
            }

            match unit {
                IntervalUnit::Minutes => {
                    if 60 % interval != 0 {
                        return Err(ScheduleError::cron(format!(
                            "not expressible as cron (*/{interval} breaks at hour boundaries)"
                        )));
                    }
                    Ok(format!("*/{interval} * * * *"))
                }
                IntervalUnit::Hours => Ok(format!("0 */{interval} * * *")),
            }
        }

        ScheduleExpr::WeekRepeat { .. } => Err(ScheduleError::cron(
            "not expressible as cron (multi-week intervals not supported)",
        )),

        ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        } => {
            if *interval > 1 {
                return Err(ScheduleError::cron(
                    "not expressible as cron (multi-month intervals not supported)",
                ));
            }
            if times.len() != 1 {
                return Err(ScheduleError::cron(
                    "not expressible as cron (multiple times not supported)",
                ));
            }
            let time = &times[0];
            match target {
                MonthTarget::Days(_) => {
                    let expanded = target.expand_days();
                    let dom = expanded
                        .iter()
                        .map(|d| d.to_string())
                        .collect::<Vec<_>>()
                        .join(",");
                    Ok(format!("{} {} {} * *", time.minute, time.hour, dom))
                }
                MonthTarget::LastDay => Err(ScheduleError::cron(
                    "not expressible as cron (last day of month not supported)",
                )),
                MonthTarget::LastWeekday => Err(ScheduleError::cron(
                    "not expressible as cron (last weekday of month not supported)",
                )),
            }
        }

        ScheduleExpr::OrdinalRepeat { .. } => Err(ScheduleError::cron(
            "not expressible as cron (ordinal weekday of month not supported)",
        )),

        ScheduleExpr::SingleDate { .. } => Err(ScheduleError::cron(
            "not expressible as cron (single dates are not repeating)",
        )),

        ScheduleExpr::YearRepeat { .. } => Err(ScheduleError::cron(
            "not expressible as cron (yearly schedules not supported in 5-field cron)",
        )),
    }
}

fn day_filter_to_cron_dow(filter: &DayFilter) -> Result<String, ScheduleError> {
    match filter {
        DayFilter::Every => Ok("*".to_string()),
        DayFilter::Weekday => Ok("1-5".to_string()),
        DayFilter::Weekend => Ok("0,6".to_string()),
        DayFilter::Days(days) => {
            let mut nums: Vec<u8> = days.iter().map(|d| cron_dow_number(*d)).collect();
            nums.sort();
            Ok(nums
                .iter()
                .map(|n| n.to_string())
                .collect::<Vec<_>>()
                .join(","))
        }
    }
}

/// Cron uses 0=Sunday, 1=Monday, ..., 6=Saturday.
fn cron_dow_number(day: Weekday) -> u8 {
    match day {
        Weekday::Sunday => 0,
        Weekday::Monday => 1,
        Weekday::Tuesday => 2,
        Weekday::Wednesday => 3,
        Weekday::Thursday => 4,
        Weekday::Friday => 5,
        Weekday::Saturday => 6,
    }
}

// ============================================================================
// from_cron: Parse 5-field cron expressions (and @ shortcuts)
// ============================================================================

/// Parse a 5-field cron expression into a Schedule.
pub fn from_cron(cron: &str) -> Result<Schedule, ScheduleError> {
    let cron = cron.trim();

    // Handle @ shortcuts first
    if cron.starts_with('@') {
        return parse_cron_shortcut(cron);
    }

    let fields: Vec<&str> = cron.split_whitespace().collect();
    if fields.len() != 5 {
        return Err(ScheduleError::cron(format!(
            "expected 5 cron fields, got {}",
            fields.len()
        )));
    }

    let minute_field = fields[0];
    let hour_field = fields[1];
    let dom_field = fields[2];
    let month_field = fields[3];
    let dow_field = fields[4];

    // Normalize ? to * (they're semantically equivalent for our purposes)
    let dom_field = if dom_field == "?" { "*" } else { dom_field };
    let dow_field = if dow_field == "?" { "*" } else { dow_field };

    // Parse month field into during clause
    let during = parse_month_field(month_field)?;

    // Check for special DOW patterns: nth weekday (#), last weekday (5L)
    if let Some(schedule) =
        try_parse_nth_weekday(minute_field, hour_field, dom_field, dow_field, &during)?
    {
        return Ok(schedule);
    }

    // Check for L (last day) or LW (last weekday) in DOM
    if let Some(schedule) =
        try_parse_last_day(minute_field, hour_field, dom_field, dow_field, &during)?
    {
        return Ok(schedule);
    }

    // Check for W (nearest weekday) - not yet supported
    if dom_field.ends_with('W') && dom_field != "LW" {
        return Err(ScheduleError::cron("W (nearest weekday) not yet supported"));
    }

    // Check for interval patterns: */N or range/N
    if let Some(schedule) =
        try_parse_interval(minute_field, hour_field, dom_field, dow_field, &during)?
    {
        return Ok(schedule);
    }

    // Standard time-based cron
    let minute: u8 = parse_single_value(minute_field, "minute", 0, 59)?;
    let hour: u8 = parse_single_value(hour_field, "hour", 0, 23)?;
    let time = TimeOfDay { hour, minute };

    // DOM-based (monthly) - when DOM is specified and DOW is *
    if dom_field != "*" && dow_field == "*" {
        let target = parse_dom_field(dom_field)?;
        let mut schedule = Schedule::new(ScheduleExpr::MonthRepeat {
            interval: 1,
            target,
            times: vec![time],
        });
        schedule.during = during;
        return Ok(schedule);
    }

    // DOW-based (day repeat)
    let days = parse_cron_dow(dow_field)?;
    let mut schedule = Schedule::new(ScheduleExpr::DayRepeat {
        interval: 1,
        days,
        times: vec![time],
    });
    schedule.during = during;
    Ok(schedule)
}

/// Parse @ shortcuts like @daily, @hourly, etc.
fn parse_cron_shortcut(cron: &str) -> Result<Schedule, ScheduleError> {
    match cron.to_lowercase().as_str() {
        "@yearly" | "@annually" => Ok(Schedule::new(ScheduleExpr::YearRepeat {
            interval: 1,
            target: YearTarget::Date {
                month: MonthName::January,
                day: 1,
            },
            times: vec![TimeOfDay { hour: 0, minute: 0 }],
        })),
        "@monthly" => Ok(Schedule::new(ScheduleExpr::MonthRepeat {
            interval: 1,
            target: MonthTarget::Days(vec![DayOfMonthSpec::Single(1)]),
            times: vec![TimeOfDay { hour: 0, minute: 0 }],
        })),
        "@weekly" => Ok(Schedule::new(ScheduleExpr::DayRepeat {
            interval: 1,
            days: DayFilter::Days(vec![Weekday::Sunday]),
            times: vec![TimeOfDay { hour: 0, minute: 0 }],
        })),
        "@daily" | "@midnight" => Ok(Schedule::new(ScheduleExpr::DayRepeat {
            interval: 1,
            days: DayFilter::Every,
            times: vec![TimeOfDay { hour: 0, minute: 0 }],
        })),
        "@hourly" => Ok(Schedule::new(ScheduleExpr::IntervalRepeat {
            interval: 1,
            unit: IntervalUnit::Hours,
            from: TimeOfDay { hour: 0, minute: 0 },
            to: TimeOfDay {
                hour: 23,
                minute: 59,
            },
            day_filter: None,
        })),
        _ => Err(ScheduleError::cron(format!("unknown @ shortcut: {cron}"))),
    }
}

/// Parse month field into a Vec<MonthName> for the `during` clause.
fn parse_month_field(field: &str) -> Result<Vec<MonthName>, ScheduleError> {
    if field == "*" {
        return Ok(vec![]);
    }

    let mut months = Vec::new();
    for part in field.split(',') {
        // Check for step values FIRST (e.g., 1-12/3 or */3)
        if let Some((range, step)) = part.split_once('/') {
            let (start, end) = if range == "*" {
                (1u8, 12u8)
            } else if let Some((s, e)) = range.split_once('-') {
                let start_month = parse_month_value(s)?;
                let end_month = parse_month_value(e)?;
                (start_month.number(), end_month.number())
            } else {
                return Err(ScheduleError::cron(format!(
                    "invalid month step expression: {}",
                    part
                )));
            };
            let step: u8 = step
                .parse()
                .map_err(|_| ScheduleError::cron(format!("invalid month step value: {}", step)))?;
            if step == 0 {
                return Err(ScheduleError::cron("step cannot be 0"));
            }
            let mut n = start;
            while n <= end {
                months.push(month_from_number(n)?);
                n += step;
            }
        } else if let Some((start, end)) = part.split_once('-') {
            // Range like 1-3 or JAN-MAR
            let start_month = parse_month_value(start)?;
            let end_month = parse_month_value(end)?;
            let start_num = start_month.number();
            let end_num = end_month.number();
            if start_num > end_num {
                return Err(ScheduleError::cron(format!(
                    "invalid month range: {} > {}",
                    start, end
                )));
            }
            for n in start_num..=end_num {
                months.push(month_from_number(n)?);
            }
        } else {
            // Single month
            months.push(parse_month_value(part)?);
        }
    }

    Ok(months)
}

/// Parse a single month value (number 1-12 or name JAN-DEC).
fn parse_month_value(s: &str) -> Result<MonthName, ScheduleError> {
    // Try as number first
    if let Ok(n) = s.parse::<u8>() {
        return month_from_number(n);
    }
    // Try as name
    parse_month_name(s).ok_or_else(|| ScheduleError::cron(format!("invalid month: {}", s)))
}

fn month_from_number(n: u8) -> Result<MonthName, ScheduleError> {
    match n {
        1 => Ok(MonthName::January),
        2 => Ok(MonthName::February),
        3 => Ok(MonthName::March),
        4 => Ok(MonthName::April),
        5 => Ok(MonthName::May),
        6 => Ok(MonthName::June),
        7 => Ok(MonthName::July),
        8 => Ok(MonthName::August),
        9 => Ok(MonthName::September),
        10 => Ok(MonthName::October),
        11 => Ok(MonthName::November),
        12 => Ok(MonthName::December),
        _ => Err(ScheduleError::cron(format!("invalid month number: {}", n))),
    }
}

/// Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday).
fn try_parse_nth_weekday(
    minute_field: &str,
    hour_field: &str,
    dom_field: &str,
    dow_field: &str,
    during: &[MonthName],
) -> Result<Option<Schedule>, ScheduleError> {
    // Check for # pattern (nth weekday of month)
    if let Some((dow_str, nth_str)) = dow_field.split_once('#') {
        let dow_num = parse_dow_value(dow_str)?;
        let weekday = cron_dow_to_weekday(dow_num)?;
        let nth: u8 = nth_str
            .parse()
            .map_err(|_| ScheduleError::cron(format!("invalid nth value: {}", nth_str)))?;
        if nth == 0 || nth > 5 {
            return Err(ScheduleError::cron(format!("nth must be 1-5, got {}", nth)));
        }
        let ordinal = match nth {
            1 => OrdinalPosition::First,
            2 => OrdinalPosition::Second,
            3 => OrdinalPosition::Third,
            4 => OrdinalPosition::Fourth,
            5 => OrdinalPosition::Fifth,
            _ => unreachable!(),
        };

        if dom_field != "*" && dom_field != "?" {
            return Err(ScheduleError::cron(
                "DOM must be * when using # for nth weekday",
            ));
        }

        let minute: u8 = parse_single_value(minute_field, "minute", 0, 59)?;
        let hour: u8 = parse_single_value(hour_field, "hour", 0, 23)?;

        let mut schedule = Schedule::new(ScheduleExpr::OrdinalRepeat {
            interval: 1,
            ordinal,
            day: weekday,
            times: vec![TimeOfDay { hour, minute }],
        });
        schedule.during = during.to_vec();
        return Ok(Some(schedule));
    }

    // Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
    if dow_field.ends_with('L') && dow_field.len() > 1 {
        let dow_str = &dow_field[..dow_field.len() - 1];
        let dow_num = parse_dow_value(dow_str)?;
        let weekday = cron_dow_to_weekday(dow_num)?;

        if dom_field != "*" && dom_field != "?" {
            return Err(ScheduleError::cron(
                "DOM must be * when using nL for last weekday",
            ));
        }

        let minute: u8 = parse_single_value(minute_field, "minute", 0, 59)?;
        let hour: u8 = parse_single_value(hour_field, "hour", 0, 23)?;

        let mut schedule = Schedule::new(ScheduleExpr::OrdinalRepeat {
            interval: 1,
            ordinal: OrdinalPosition::Last,
            day: weekday,
            times: vec![TimeOfDay { hour, minute }],
        });
        schedule.during = during.to_vec();
        return Ok(Some(schedule));
    }

    Ok(None)
}

/// Try to parse L (last day) or LW (last weekday) patterns.
fn try_parse_last_day(
    minute_field: &str,
    hour_field: &str,
    dom_field: &str,
    dow_field: &str,
    during: &[MonthName],
) -> Result<Option<Schedule>, ScheduleError> {
    if dom_field != "L" && dom_field != "LW" {
        return Ok(None);
    }

    if dow_field != "*" && dow_field != "?" {
        return Err(ScheduleError::cron(
            "DOW must be * when using L or LW in DOM",
        ));
    }

    let minute: u8 = parse_single_value(minute_field, "minute", 0, 59)?;
    let hour: u8 = parse_single_value(hour_field, "hour", 0, 23)?;

    let target = if dom_field == "LW" {
        MonthTarget::LastWeekday
    } else {
        MonthTarget::LastDay
    };

    let mut schedule = Schedule::new(ScheduleExpr::MonthRepeat {
        interval: 1,
        target,
        times: vec![TimeOfDay { hour, minute }],
    });
    schedule.during = during.to_vec();
    Ok(Some(schedule))
}

/// Try to parse interval patterns: */N, range/N in minute or hour fields.
fn try_parse_interval(
    minute_field: &str,
    hour_field: &str,
    dom_field: &str,
    dow_field: &str,
    during: &[MonthName],
) -> Result<Option<Schedule>, ScheduleError> {
    // Minute interval: */N or range/N
    if minute_field.contains('/') {
        let (range_part, step_str) = minute_field
            .split_once('/')
            .ok_or_else(|| ScheduleError::cron("invalid minute interval"))?;

        let interval: u32 = step_str
            .parse()
            .map_err(|_| ScheduleError::cron("invalid minute interval value"))?;

        if interval == 0 {
            return Err(ScheduleError::cron("step cannot be 0"));
        }

        let (from_minute, to_minute) = if range_part == "*" {
            (0u8, 59u8)
        } else if let Some((start, end)) = range_part.split_once('-') {
            let s: u8 = start
                .parse()
                .map_err(|_| ScheduleError::cron("invalid minute range"))?;
            let e: u8 = end
                .parse()
                .map_err(|_| ScheduleError::cron("invalid minute range"))?;
            if s > e {
                return Err(ScheduleError::cron(format!(
                    "range start must be <= end: {}-{}",
                    s, e
                )));
            }
            (s, e)
        } else {
            // Single value with step (e.g., 0/15) - treat as starting point
            let s: u8 = range_part
                .parse()
                .map_err(|_| ScheduleError::cron("invalid minute value"))?;
            (s, 59)
        };

        // Determine the hour window
        let (from_hour, to_hour) = if hour_field == "*" {
            (0u8, 23u8)
        } else if let Some((start, end)) = hour_field.split_once('-') {
            let s: u8 = start
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour range"))?;
            let e: u8 = end
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour range"))?;
            (s, e)
        } else if hour_field.contains('/') {
            // Hour also has step - this is complex, handle as hour interval
            return Ok(None);
        } else {
            let h: u8 = hour_field
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour"))?;
            (h, h)
        };

        // Check if this should be a day filter
        let day_filter = if dow_field == "*" {
            None
        } else {
            Some(parse_cron_dow(dow_field)?)
        };

        if dom_field == "*" || dom_field == "?" {
            // Determine the end minute based on context
            let end_minute = if from_minute == 0 && to_minute == 59 && to_hour == 23 {
                // Full day: 00:00 to 23:59
                59
            } else if from_minute == 0 && to_minute == 59 {
                // Partial day with full minutes range: use :00 for cleaner output
                0
            } else {
                to_minute
            };

            let mut schedule = Schedule::new(ScheduleExpr::IntervalRepeat {
                interval,
                unit: IntervalUnit::Minutes,
                from: TimeOfDay {
                    hour: from_hour,
                    minute: from_minute,
                },
                to: TimeOfDay {
                    hour: to_hour,
                    minute: end_minute,
                },
                day_filter,
            });
            schedule.during = during.to_vec();
            return Ok(Some(schedule));
        }
    }

    // Hour interval: 0 */N or 0 range/N
    if hour_field.contains('/') && (minute_field == "0" || minute_field == "00") {
        let (range_part, step_str) = hour_field
            .split_once('/')
            .ok_or_else(|| ScheduleError::cron("invalid hour interval"))?;

        let interval: u32 = step_str
            .parse()
            .map_err(|_| ScheduleError::cron("invalid hour interval value"))?;

        if interval == 0 {
            return Err(ScheduleError::cron("step cannot be 0"));
        }

        let (from_hour, to_hour) = if range_part == "*" {
            (0u8, 23u8)
        } else if let Some((start, end)) = range_part.split_once('-') {
            let s: u8 = start
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour range"))?;
            let e: u8 = end
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour range"))?;
            if s > e {
                return Err(ScheduleError::cron(format!(
                    "range start must be <= end: {}-{}",
                    s, e
                )));
            }
            (s, e)
        } else {
            let h: u8 = range_part
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour value"))?;
            (h, 23)
        };

        if (dom_field == "*" || dom_field == "?") && (dow_field == "*" || dow_field == "?") {
            // Use :59 only for full day (00:00 to 23:59), otherwise use :00
            let end_minute = if from_hour == 0 && to_hour == 23 {
                59
            } else {
                0
            };

            let mut schedule = Schedule::new(ScheduleExpr::IntervalRepeat {
                interval,
                unit: IntervalUnit::Hours,
                from: TimeOfDay {
                    hour: from_hour,
                    minute: 0,
                },
                to: TimeOfDay {
                    hour: to_hour,
                    minute: end_minute,
                },
                day_filter: None,
            });
            schedule.during = during.to_vec();
            return Ok(Some(schedule));
        }
    }

    Ok(None)
}

/// Parse a DOM field into a MonthTarget.
fn parse_dom_field(field: &str) -> Result<MonthTarget, ScheduleError> {
    let mut specs = Vec::new();

    for part in field.split(',') {
        if let Some((range_part, step_str)) = part.split_once('/') {
            // Step value: 1-31/2 or */5
            let (start, end) = if range_part == "*" {
                (1u8, 31u8)
            } else if let Some((s, e)) = range_part.split_once('-') {
                let start: u8 = s
                    .parse()
                    .map_err(|_| ScheduleError::cron(format!("invalid DOM range start: {}", s)))?;
                let end: u8 = e
                    .parse()
                    .map_err(|_| ScheduleError::cron(format!("invalid DOM range end: {}", e)))?;
                if start > end {
                    return Err(ScheduleError::cron(format!(
                        "range start must be <= end: {}-{}",
                        start, end
                    )));
                }
                (start, end)
            } else {
                let start: u8 = range_part.parse().map_err(|_| {
                    ScheduleError::cron(format!("invalid DOM value: {}", range_part))
                })?;
                (start, 31)
            };

            let step: u8 = step_str
                .parse()
                .map_err(|_| ScheduleError::cron(format!("invalid DOM step: {}", step_str)))?;
            if step == 0 {
                return Err(ScheduleError::cron("step cannot be 0"));
            }

            validate_dom(start)?;
            validate_dom(end)?;

            let mut d = start;
            while d <= end {
                specs.push(DayOfMonthSpec::Single(d));
                d += step;
            }
        } else if let Some((start_str, end_str)) = part.split_once('-') {
            // Range: 1-5
            let start: u8 = start_str.parse().map_err(|_| {
                ScheduleError::cron(format!("invalid DOM range start: {}", start_str))
            })?;
            let end: u8 = end_str
                .parse()
                .map_err(|_| ScheduleError::cron(format!("invalid DOM range end: {}", end_str)))?;
            if start > end {
                return Err(ScheduleError::cron(format!(
                    "range start must be <= end: {}-{}",
                    start, end
                )));
            }
            validate_dom(start)?;
            validate_dom(end)?;
            specs.push(DayOfMonthSpec::Range(start, end));
        } else {
            // Single: 15
            let day: u8 = part
                .parse()
                .map_err(|_| ScheduleError::cron(format!("invalid DOM value: {}", part)))?;
            validate_dom(day)?;
            specs.push(DayOfMonthSpec::Single(day));
        }
    }

    Ok(MonthTarget::Days(specs))
}

fn validate_dom(day: u8) -> Result<(), ScheduleError> {
    if day < 1 || day > 31 {
        return Err(ScheduleError::cron(format!(
            "DOM must be 1-31, got {}",
            day
        )));
    }
    Ok(())
}

/// Parse a DOW field into a DayFilter.
fn parse_cron_dow(field: &str) -> Result<DayFilter, ScheduleError> {
    if field == "*" {
        return Ok(DayFilter::Every);
    }

    let mut days = Vec::new();

    for part in field.split(',') {
        if let Some((range_part, step_str)) = part.split_once('/') {
            // Step value: 0-6/2 or */2
            let (start, end) = if range_part == "*" {
                (0u8, 6u8)
            } else if let Some((s, e)) = range_part.split_once('-') {
                let start = parse_dow_value_raw(s)?;
                let end = parse_dow_value_raw(e)?;
                if start > end {
                    return Err(ScheduleError::cron(format!(
                        "range start must be <= end: {}-{}",
                        s, e
                    )));
                }
                (start, end)
            } else {
                let start = parse_dow_value_raw(range_part)?;
                (start, 6)
            };

            let step: u8 = step_str
                .parse()
                .map_err(|_| ScheduleError::cron(format!("invalid DOW step: {}", step_str)))?;
            if step == 0 {
                return Err(ScheduleError::cron("step cannot be 0"));
            }

            let mut d = start;
            while d <= end {
                days.push(cron_dow_to_weekday(d)?);
                d += step;
            }
        } else if let Some((start_str, end_str)) = part.split_once('-') {
            // Range: 1-5 or MON-FRI
            // Parse without normalizing 7 to 0 for range purposes
            let start = parse_dow_value_raw(start_str)?;
            let end = parse_dow_value_raw(end_str)?;
            if start > end {
                return Err(ScheduleError::cron(format!(
                    "range start must be <= end: {}-{}",
                    start_str, end_str
                )));
            }
            for d in start..=end {
                // Normalize 7 to 0 (Sunday) when converting to weekday
                let normalized = if d == 7 { 0 } else { d };
                days.push(cron_dow_to_weekday(normalized)?);
            }
        } else {
            // Single: 1 or MON
            let dow = parse_dow_value(part)?;
            days.push(cron_dow_to_weekday(dow)?);
        }
    }

    // Check for special patterns
    if days.len() == 5 {
        let mut sorted = days.clone();
        sorted.sort_by_key(|d| d.number());
        if sorted == Weekday::all_weekdays() {
            return Ok(DayFilter::Weekday);
        }
    }
    if days.len() == 2 {
        let mut sorted = days.clone();
        sorted.sort_by_key(|d| d.number());
        if sorted == vec![Weekday::Saturday, Weekday::Sunday] {
            return Ok(DayFilter::Weekend);
        }
    }

    Ok(DayFilter::Days(days))
}

/// Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0.
fn parse_dow_value(s: &str) -> Result<u8, ScheduleError> {
    let raw = parse_dow_value_raw(s)?;
    // Normalize 7 to 0 (both mean Sunday)
    Ok(if raw == 7 { 0 } else { raw })
}

/// Parse a DOW value without normalizing 7 to 0 (for range checking).
fn parse_dow_value_raw(s: &str) -> Result<u8, ScheduleError> {
    // Try as number first
    if let Ok(n) = s.parse::<u8>() {
        if n > 7 {
            return Err(ScheduleError::cron(format!("DOW must be 0-7, got {}", n)));
        }
        return Ok(n);
    }
    // Try as name
    match s.to_uppercase().as_str() {
        "SUN" => Ok(0),
        "MON" => Ok(1),
        "TUE" => Ok(2),
        "WED" => Ok(3),
        "THU" => Ok(4),
        "FRI" => Ok(5),
        "SAT" => Ok(6),
        _ => Err(ScheduleError::cron(format!("invalid DOW: {}", s))),
    }
}

fn cron_dow_to_weekday(n: u8) -> Result<Weekday, ScheduleError> {
    match n {
        0 | 7 => Ok(Weekday::Sunday),
        1 => Ok(Weekday::Monday),
        2 => Ok(Weekday::Tuesday),
        3 => Ok(Weekday::Wednesday),
        4 => Ok(Weekday::Thursday),
        5 => Ok(Weekday::Friday),
        6 => Ok(Weekday::Saturday),
        _ => Err(ScheduleError::cron(format!("invalid DOW number: {n}"))),
    }
}

/// Parse a single numeric value with validation.
fn parse_single_value(field: &str, name: &str, min: u8, max: u8) -> Result<u8, ScheduleError> {
    let value: u8 = field
        .parse()
        .map_err(|_| ScheduleError::cron(format!("invalid {} field: {}", name, field)))?;
    if value < min || value > max {
        return Err(ScheduleError::cron(format!(
            "{} must be {}-{}, got {}",
            name, min, max, value
        )));
    }
    Ok(value)
}

/// Explain a cron expression in human-readable form (best effort).
pub fn explain_cron(cron: &str) -> Result<String, ScheduleError> {
    let schedule = from_cron(cron)?;
    let mut explanation = schedule.to_string();

    // Add warnings for cron quirks
    let fields: Vec<&str> = cron.split_whitespace().collect();
    if fields.len() == 5 {
        if let Some(minute_field) = fields.first() {
            if let Some(interval_str) = minute_field.strip_prefix("*/") {
                if let Ok(interval) = interval_str.parse::<u32>() {
                    if 60 % interval != 0 {
                        explanation.push_str(&format!(
                            "\nnote: cron */{interval} actually fires at {} each hour, not true {interval}-min intervals",
                            generate_cron_minute_fires(interval)
                        ));
                    }
                }
            }
        }
    }

    Ok(explanation)
}

fn generate_cron_minute_fires(interval: u32) -> String {
    let mut minutes = Vec::new();
    let mut m = 0;
    while m < 60 {
        minutes.push(format!(":{:02}", m));
        m += interval;
    }
    minutes.join(" and ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    #[test]
    fn test_to_cron_every_day() {
        let s = parse("every day at 9:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 9 * * *");
    }

    #[test]
    fn test_to_cron_weekday() {
        let s = parse("every weekday at 9:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 9 * * 1-5");
    }

    #[test]
    fn test_to_cron_weekend() {
        let s = parse("every weekend at 10:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 10 * * 0,6");
    }

    #[test]
    fn test_to_cron_specific_days() {
        let s = parse("every mon, wed, fri at 9:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 9 * * 1,3,5");
    }

    #[test]
    fn test_to_cron_interval_minutes() {
        let s = parse("every 30 min from 00:00 to 23:59").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "*/30 * * * *");
    }

    #[test]
    fn test_to_cron_interval_hours() {
        let s = parse("every 2 hours from 00:00 to 23:59").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 */2 * * *");
    }

    #[test]
    fn test_to_cron_month_single_day() {
        let s = parse("every month on the 1st at 9:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 9 1 * *");
    }

    #[test]
    fn test_to_cron_month_multiple_days() {
        let s = parse("every month on the 1st, 15th at 9:00").unwrap();
        assert_eq!(to_cron(&s).unwrap(), "0 9 1,15 * *");
    }

    #[test]
    fn test_to_cron_not_expressible_45min() {
        let s = parse("every 45 min from 09:00 to 17:00").unwrap();
        assert!(to_cron(&s).is_err());
    }

    #[test]
    fn test_to_cron_not_expressible_week() {
        let s = parse("every 2 weeks on monday at 9:00").unwrap();
        assert!(to_cron(&s).is_err());
    }

    #[test]
    fn test_to_cron_not_expressible_last_day() {
        let s = parse("every month on the last day at 17:00").unwrap();
        assert!(to_cron(&s).is_err());
    }

    #[test]
    fn test_to_cron_not_expressible_ordinal() {
        let s = parse("first monday of every month at 10:00").unwrap();
        assert!(to_cron(&s).is_err());
    }

    #[test]
    fn test_to_cron_not_expressible_yearly() {
        let s = parse("every year on dec 25 at 00:00").unwrap();
        assert!(to_cron(&s).is_err());
    }

    #[test]
    fn test_from_cron_every_day() {
        let s = from_cron("0 9 * * *").unwrap();
        assert_eq!(s.to_string(), "every day at 09:00");
    }

    #[test]
    fn test_from_cron_weekday() {
        let s = from_cron("0 9 * * 1-5").unwrap();
        assert_eq!(s.to_string(), "every weekday at 09:00");
    }

    #[test]
    fn test_from_cron_monthly() {
        let s = from_cron("0 9 1 * *").unwrap();
        assert_eq!(s.to_string(), "every month on the 1st at 09:00");
    }

    #[test]
    fn test_from_cron_interval_minutes() {
        let s = from_cron("*/30 * * * *").unwrap();
        assert_eq!(s.to_string(), "every 30 min from 00:00 to 23:59");
    }

    #[test]
    fn test_from_cron_dom_range() {
        let s = from_cron("0 9 1-5 * *").unwrap();
        assert_eq!(s.to_string(), "every month on the 1st to 5th at 09:00");
    }

    #[test]
    fn test_from_cron_dow_range() {
        let s = from_cron("0 9 * * 2-4").unwrap();
        assert_eq!(s.to_string(), "every tuesday, wednesday, thursday at 09:00");
    }

    #[test]
    fn test_from_cron_month_field() {
        let s = from_cron("0 9 1 1,7 *").unwrap();
        assert_eq!(
            s.to_string(),
            "every month on the 1st at 09:00 during jan, jul"
        );
    }

    #[test]
    fn test_from_cron_at_daily() {
        let s = from_cron("@daily").unwrap();
        assert_eq!(s.to_string(), "every day at 00:00");
    }

    #[test]
    fn test_from_cron_last_day() {
        let s = from_cron("0 9 L * *").unwrap();
        assert_eq!(s.to_string(), "every month on the last day at 09:00");
    }

    #[test]
    fn test_from_cron_nth_weekday() {
        let s = from_cron("0 9 * * 1#1").unwrap();
        assert_eq!(s.to_string(), "first monday of every month at 09:00");
    }

    #[test]
    fn test_from_cron_question_mark() {
        let s = from_cron("0 9 ? * 1").unwrap();
        assert_eq!(s.to_string(), "every monday at 09:00");
    }

    #[test]
    fn test_from_cron_named_dow() {
        let s = from_cron("0 9 * * MON,WED,FRI").unwrap();
        assert_eq!(s.to_string(), "every monday, wednesday, friday at 09:00");
    }

    #[test]
    fn test_from_cron_named_month() {
        let s = from_cron("0 9 1 JAN,JUL *").unwrap();
        assert_eq!(
            s.to_string(),
            "every month on the 1st at 09:00 during jan, jul"
        );
    }
}
