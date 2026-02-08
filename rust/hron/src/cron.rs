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
        ScheduleExpr::DayRepeat { days, times } => {
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

        ScheduleExpr::MonthRepeat { target, times } => {
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

/// Parse a 5-field cron expression into a Schedule.
pub fn from_cron(cron: &str) -> Result<Schedule, ScheduleError> {
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
    let _month_field = fields[3]; // always * for now
    let dow_field = fields[4];

    // Check for interval patterns: */N
    if let Some(interval_str) = minute_field.strip_prefix("*/") {
        let interval: u32 = interval_str
            .parse()
            .map_err(|_| ScheduleError::cron("invalid minute interval"))?;

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
        } else {
            // Single hour — not really an interval pattern
            let h: u8 = hour_field
                .parse()
                .map_err(|_| ScheduleError::cron("invalid hour"))?;
            (h, h)
        };

        let day_filter = if dow_field == "*" {
            None
        } else {
            Some(parse_cron_dow(dow_field)?)
        };

        if dom_field == "*" {
            return Ok(Schedule::new(ScheduleExpr::IntervalRepeat {
                interval,
                unit: IntervalUnit::Minutes,
                from: TimeOfDay {
                    hour: from_hour,
                    minute: 0,
                },
                to: TimeOfDay {
                    hour: to_hour,
                    minute: if to_hour == 23 { 59 } else { 0 },
                },
                day_filter,
            }));
        }
    }

    if hour_field.starts_with("*/") && minute_field == "0" {
        let interval: u32 = hour_field[2..]
            .parse()
            .map_err(|_| ScheduleError::cron("invalid hour interval"))?;
        if dom_field == "*" && dow_field == "*" {
            return Ok(Schedule::new(ScheduleExpr::IntervalRepeat {
                interval,
                unit: IntervalUnit::Hours,
                from: TimeOfDay { hour: 0, minute: 0 },
                to: TimeOfDay {
                    hour: 23,
                    minute: 59,
                },
                day_filter: None,
            }));
        }
    }

    // Standard time-based cron
    let minute: u8 = minute_field
        .parse()
        .map_err(|_| ScheduleError::cron(format!("invalid minute field: {minute_field}")))?;
    let hour: u8 = hour_field
        .parse()
        .map_err(|_| ScheduleError::cron(format!("invalid hour field: {hour_field}")))?;
    let time = TimeOfDay { hour, minute };

    // DOM-based (monthly)
    if dom_field != "*" && dow_field == "*" {
        let days: Result<Vec<u8>, _> = dom_field.split(',').map(|s| s.parse::<u8>()).collect();
        let days =
            days.map_err(|_| ScheduleError::cron(format!("invalid DOM field: {dom_field}")))?;
        let specs = days.into_iter().map(DayOfMonthSpec::Single).collect();
        return Ok(Schedule::new(ScheduleExpr::MonthRepeat {
            target: MonthTarget::Days(specs),
            times: vec![time],
        }));
    }

    // DOW-based (day repeat)
    let days = parse_cron_dow(dow_field)?;
    Ok(Schedule::new(ScheduleExpr::DayRepeat {
        days,
        times: vec![time],
    }))
}

fn parse_cron_dow(field: &str) -> Result<DayFilter, ScheduleError> {
    if field == "*" {
        return Ok(DayFilter::Every);
    }
    if field == "1-5" {
        return Ok(DayFilter::Weekday);
    }
    if field == "0,6" || field == "6,0" {
        return Ok(DayFilter::Weekend);
    }

    // Comma-separated day numbers
    let nums: Result<Vec<u8>, _> = field.split(',').map(|s| s.parse::<u8>()).collect();
    let nums = nums.map_err(|_| ScheduleError::cron(format!("invalid DOW field: {field}")))?;

    let days: Vec<Weekday> = nums
        .iter()
        .map(|&n| cron_dow_to_weekday(n))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(DayFilter::Days(days))
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
}
