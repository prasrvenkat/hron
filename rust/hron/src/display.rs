use std::fmt;

use crate::ast::*;

impl fmt::Display for Schedule {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Write the expression
        write!(f, "{}", self.expr)?;

        // Write trailing clauses in order: except, until, starting, during, timezone
        if !self.except.is_empty() {
            write!(f, " except ")?;
            for (i, exc) in self.except.iter().enumerate() {
                if i > 0 {
                    write!(f, ", ")?;
                }
                match exc {
                    Exception::Named { month, day } => write!(f, "{} {}", month.as_str(), day)?,
                    Exception::Iso(d) => write!(f, "{d}")?,
                }
            }
        }

        if let Some(until) = &self.until {
            match until {
                UntilSpec::Iso(d) => write!(f, " until {d}")?,
                UntilSpec::Named { month, day } => write!(f, " until {} {}", month.as_str(), day)?,
            }
        }

        if let Some(anchor) = &self.anchor {
            write!(f, " starting {anchor}")?;
        }

        if !self.during.is_empty() {
            write!(f, " during ")?;
            for (i, month) in self.during.iter().enumerate() {
                if i > 0 {
                    write!(f, ", ")?;
                }
                write!(f, "{}", month.as_str())?;
            }
        }

        if let Some(tz) = &self.timezone {
            write!(f, " in {tz}")?;
        }

        Ok(())
    }
}

impl fmt::Display for ScheduleExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ScheduleExpr::IntervalRepeat {
                interval,
                unit,
                from,
                to,
                day_filter,
            } => {
                write!(f, "every {interval} {}", unit_display(*interval, *unit))?;
                write!(f, " from {from} to {to}")?;
                if let Some(df) = day_filter {
                    write!(f, " on {df}")?;
                }
            }
            ScheduleExpr::DayRepeat { days, times } => {
                write!(f, "every {days} at ")?;
                write_time_list(f, times)?;
            }
            ScheduleExpr::WeekRepeat {
                interval,
                days,
                times,
            } => {
                write!(f, "every {interval} weeks on ")?;
                write_day_list(f, days)?;
                write!(f, " at ")?;
                write_time_list(f, times)?;
            }
            ScheduleExpr::MonthRepeat { target, times } => {
                write!(f, "every month on the ")?;
                match target {
                    MonthTarget::Days(specs) => write_ordinal_day_specs(f, specs)?,
                    MonthTarget::LastDay => write!(f, "last day")?,
                    MonthTarget::LastWeekday => write!(f, "last weekday")?,
                }
                write!(f, " at ")?;
                write_time_list(f, times)?;
            }
            ScheduleExpr::OrdinalRepeat {
                ordinal,
                day,
                times,
            } => {
                write!(
                    f,
                    "{} {} of every month at ",
                    ordinal.as_str(),
                    day.as_str()
                )?;
                write_time_list(f, times)?;
            }
            ScheduleExpr::SingleDate { date, times } => {
                write!(f, "on ")?;
                match date {
                    DateSpec::Named { month, day } => {
                        write!(f, "{} {day}", month.as_str())?;
                    }
                    DateSpec::Iso(d) => {
                        write!(f, "{d}")?;
                    }
                }
                write!(f, " at ")?;
                write_time_list(f, times)?;
            }
            ScheduleExpr::YearRepeat { target, times } => {
                write!(f, "every year on ")?;
                match target {
                    YearTarget::Date { month, day } => {
                        write!(f, "{} {day}", month.as_str())?;
                    }
                    YearTarget::OrdinalWeekday {
                        ordinal,
                        weekday,
                        month,
                    } => {
                        write!(
                            f,
                            "the {} {} of {}",
                            ordinal.as_str(),
                            weekday.as_str(),
                            month.as_str()
                        )?;
                    }
                    YearTarget::DayOfMonth { day, month } => {
                        write!(
                            f,
                            "the {}{} of {}",
                            day,
                            ordinal_suffix(*day),
                            month.as_str()
                        )?;
                    }
                    YearTarget::LastWeekday { month } => {
                        write!(f, "the last weekday of {}", month.as_str())?;
                    }
                }
                write!(f, " at ")?;
                write_time_list(f, times)?;
            }
        }
        Ok(())
    }
}

impl fmt::Display for TimeOfDay {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:02}:{:02}", self.hour, self.minute)
    }
}

impl fmt::Display for DayFilter {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DayFilter::Every => write!(f, "day"),
            DayFilter::Weekday => write!(f, "weekday"),
            DayFilter::Weekend => write!(f, "weekend"),
            DayFilter::Days(days) => write_day_list(f, days),
        }
    }
}

fn write_time_list(f: &mut fmt::Formatter<'_>, times: &[TimeOfDay]) -> fmt::Result {
    for (i, t) in times.iter().enumerate() {
        if i > 0 {
            write!(f, ", ")?;
        }
        write!(f, "{t}")?;
    }
    Ok(())
}

fn write_day_list(f: &mut fmt::Formatter<'_>, days: &[Weekday]) -> fmt::Result {
    for (i, day) in days.iter().enumerate() {
        if i > 0 {
            write!(f, ", ")?;
        }
        write!(f, "{}", day.as_str())?;
    }
    Ok(())
}

fn write_ordinal_day_specs(f: &mut fmt::Formatter<'_>, specs: &[DayOfMonthSpec]) -> fmt::Result {
    for (i, spec) in specs.iter().enumerate() {
        if i > 0 {
            write!(f, ", ")?;
        }
        match spec {
            DayOfMonthSpec::Single(d) => write!(f, "{}{}", d, ordinal_suffix(*d))?,
            DayOfMonthSpec::Range(start, end) => {
                write!(
                    f,
                    "{}{} to {}{}",
                    start,
                    ordinal_suffix(*start),
                    end,
                    ordinal_suffix(*end)
                )?;
            }
        }
    }
    Ok(())
}

fn ordinal_suffix(n: u8) -> &'static str {
    match n % 100 {
        11..=13 => "th",
        _ => match n % 10 {
            1 => "st",
            2 => "nd",
            3 => "rd",
            _ => "th",
        },
    }
}

fn unit_display(interval: u32, unit: IntervalUnit) -> &'static str {
    match unit {
        IntervalUnit::Minutes => {
            if interval == 1 {
                "minute"
            } else {
                "min"
            }
        }
        IntervalUnit::Hours => {
            if interval == 1 {
                "hour"
            } else {
                "hours"
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use crate::parser::parse;

    #[test]
    fn test_roundtrip_every_day() {
        let s = parse("every day at 09:00").unwrap();
        assert_eq!(s.to_string(), "every day at 09:00");
    }

    #[test]
    fn test_roundtrip_weekday() {
        let s = parse("every weekday at 9:00").unwrap();
        assert_eq!(s.to_string(), "every weekday at 09:00");
    }

    #[test]
    fn test_roundtrip_interval() {
        let s = parse("every 30 min from 09:00 to 17:00").unwrap();
        assert_eq!(s.to_string(), "every 30 min from 09:00 to 17:00");
    }

    #[test]
    fn test_roundtrip_month() {
        let s = parse("every month on the 1st, 15th at 09:00").unwrap();
        assert_eq!(s.to_string(), "every month on the 1st, 15th at 09:00");
    }

    #[test]
    fn test_roundtrip_ordinal() {
        let s = parse("first monday of every month at 10:00").unwrap();
        assert_eq!(s.to_string(), "first monday of every month at 10:00");
    }

    #[test]
    fn test_roundtrip_on_named() {
        let s = parse("on feb 14 at 9:00").unwrap();
        assert_eq!(s.to_string(), "on feb 14 at 09:00");
    }

    #[test]
    fn test_roundtrip_on_iso() {
        let s = parse("on 2026-03-15 at 14:30").unwrap();
        assert_eq!(s.to_string(), "on 2026-03-15 at 14:30");
    }

    #[test]
    fn test_roundtrip_timezone() {
        let s = parse("every weekday at 9:00 in America/Vancouver").unwrap();
        assert_eq!(s.to_string(), "every weekday at 09:00 in America/Vancouver");
    }

    #[test]
    fn test_roundtrip_except() {
        let s = parse("every weekday at 9:00 except dec 25, jan 1").unwrap();
        assert_eq!(s.to_string(), "every weekday at 09:00 except dec 25, jan 1");
    }

    #[test]
    fn test_roundtrip_until_iso() {
        let s = parse("every day at 09:00 until 2026-12-31").unwrap();
        assert_eq!(s.to_string(), "every day at 09:00 until 2026-12-31");
    }

    #[test]
    fn test_roundtrip_starting() {
        let s = parse("every 2 weeks on monday at 9:00 starting 2026-01-05").unwrap();
        assert_eq!(
            s.to_string(),
            "every 2 weeks on monday at 09:00 starting 2026-01-05"
        );
    }

    #[test]
    fn test_roundtrip_year_date() {
        let s = parse("every year on dec 25 at 00:00").unwrap();
        assert_eq!(s.to_string(), "every year on dec 25 at 00:00");
    }

    #[test]
    fn test_roundtrip_year_ordinal_weekday() {
        let s = parse("every year on the first monday of march at 10:00").unwrap();
        assert_eq!(
            s.to_string(),
            "every year on the first monday of mar at 10:00"
        );
    }

    #[test]
    fn test_roundtrip_year_day_of_month() {
        let s = parse("every year on the 15th of march at 09:00").unwrap();
        assert_eq!(s.to_string(), "every year on the 15th of mar at 09:00");
    }

    #[test]
    fn test_roundtrip_year_last_weekday() {
        let s = parse("every year on the last weekday of december at 17:00").unwrap();
        assert_eq!(
            s.to_string(),
            "every year on the last weekday of dec at 17:00"
        );
    }

    #[test]
    fn test_roundtrip_all_clauses() {
        let s = parse(
            "every weekday at 9:00 except dec 25 until 2027-12-31 starting 2026-01-01 in UTC",
        )
        .unwrap();
        assert_eq!(
            s.to_string(),
            "every weekday at 09:00 except dec 25 until 2027-12-31 starting 2026-01-01 in UTC"
        );
    }

    #[test]
    fn test_roundtrip_multi_time() {
        let s = parse("every day at 9:00, 12:00, 17:00").unwrap();
        assert_eq!(s.to_string(), "every day at 09:00, 12:00, 17:00");
    }

    #[test]
    fn test_roundtrip_during() {
        let s = parse("every weekday at 9:00 during jan, jun").unwrap();
        assert_eq!(s.to_string(), "every weekday at 09:00 during jan, jun");
    }

    #[test]
    fn test_roundtrip_day_range() {
        let s = parse("every month on the 1st to 15th at 9:00").unwrap();
        assert_eq!(s.to_string(), "every month on the 1st to 15th at 09:00");
    }

    #[test]
    fn test_roundtrip_day_range_mixed() {
        let s = parse("every month on the 1st to 10th, 20th at 9:00").unwrap();
        assert_eq!(
            s.to_string(),
            "every month on the 1st to 10th, 20th at 09:00"
        );
    }

    #[test]
    fn test_roundtrip_all_new_clauses() {
        let s = parse(
            "every weekday at 9:00, 17:00 except dec 25 until 2027-12-31 during jan, mar in UTC",
        )
        .unwrap();
        assert_eq!(
            s.to_string(),
            "every weekday at 09:00, 17:00 except dec 25 until 2027-12-31 during jan, mar in UTC"
        );
    }
}
