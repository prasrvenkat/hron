// Recursive descent parser for spec/grammar.ebnf.

use crate::ast::*;
use crate::error::{ScheduleError, Span};
use crate::lexer::{Token, TokenKind};

struct Parser<'a> {
    tokens: &'a [Token],
    pos: usize,
    input: &'a str,
}

impl<'a> Parser<'a> {
    fn new(tokens: &'a [Token], input: &'a str) -> Self {
        Self {
            tokens,
            pos: 0,
            input,
        }
    }

    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.pos)
    }

    fn advance(&mut self) -> Option<&Token> {
        let tok = self.tokens.get(self.pos);
        if tok.is_some() {
            self.pos += 1;
        }
        tok
    }

    fn expect(&mut self, expected: &str) -> Result<&Token, ScheduleError> {
        match self.peek() {
            Some(_) => Ok(&self.tokens[self.pos]),
            None => Err(self.error_at_end(format!("expected {expected}"))),
        }
    }

    fn current_span(&self) -> Span {
        if let Some(tok) = self.peek() {
            tok.span
        } else if let Some(last) = self.tokens.last() {
            Span::new(last.span.end, last.span.end)
        } else {
            Span::new(0, 0)
        }
    }

    fn error(&self, message: String, span: Span) -> ScheduleError {
        ScheduleError::parse(message, span, self.input, None)
    }

    fn error_at_end(&self, message: String) -> ScheduleError {
        let span = if let Some(last) = self.tokens.last() {
            Span::new(last.span.end, last.span.end)
        } else {
            Span::new(0, 0)
        };
        ScheduleError::parse(message, span, self.input, None)
    }

    fn validate_day_number(&self, n: u32) -> Result<u8, ScheduleError> {
        if !(1..=31).contains(&n) {
            return Err(self.error(
                format!("invalid day number {n} (must be 1-31)"),
                self.current_span(),
            ));
        }
        Ok(n as u8)
    }

    fn validate_named_date(
        &self,
        month: MonthName,
        day: u8,
        span: Span,
    ) -> Result<(), ScheduleError> {
        let max = match month {
            MonthName::January => 31,
            MonthName::February => 29,
            MonthName::March => 31,
            MonthName::April => 30,
            MonthName::May => 31,
            MonthName::June => 30,
            MonthName::July => 31,
            MonthName::August => 31,
            MonthName::September => 30,
            MonthName::October => 31,
            MonthName::November => 30,
            MonthName::December => 31,
        };
        if day < 1 || day > max {
            return Err(self.error(
                format!("invalid day {} for {} (max {})", day, month.as_str(), max),
                span,
            ));
        }
        Ok(())
    }

    fn parse_day_number(&mut self, context: &str) -> Result<(u8, Span), ScheduleError> {
        let span = self.current_span();
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Number(n)) => {
                let d = self.validate_day_number(*n)?;
                self.advance();
                Ok((d, span))
            }
            Some(TokenKind::OrdinalNumber(n)) => {
                let d = self.validate_day_number(*n)?;
                self.advance();
                Ok((d, span))
            }
            _ => Err(self.error(format!("expected day number {context}"), span)),
        }
    }

    fn consume_kind(
        &mut self,
        expected: &str,
        check: impl Fn(&TokenKind) -> bool,
    ) -> Result<&Token, ScheduleError> {
        let span = self.current_span();
        match self.peek() {
            Some(tok) if check(&tok.kind) => {
                let idx = self.pos;
                self.pos += 1;
                Ok(&self.tokens[idx])
            }
            Some(tok) => Err(self.error(format!("expected {expected}, got {:?}", tok.kind), span)),
            None => Err(self.error_at_end(format!("expected {expected}"))),
        }
    }

    fn parse_expression(&mut self) -> Result<Schedule, ScheduleError> {
        let span = self.current_span();
        let expr = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Every) => {
                self.advance();
                self.parse_every()?
            }
            Some(TokenKind::On) => {
                self.advance();
                self.parse_on()?
            }
            _ => {
                return Err(self.error("expected 'every' or 'on'".into(), span));
            }
        };

        self.parse_trailing_clauses(expr)
    }

    fn parse_trailing_clauses(&mut self, expr: ScheduleExpr) -> Result<Schedule, ScheduleError> {
        let mut schedule = Schedule::new(expr);

        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Except)) {
            self.advance();
            schedule.except = self.parse_exception_list()?;
        }

        let mut until_span = None;
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Until)) {
            let start = self.current_span().start;
            self.advance();
            schedule.until = Some(self.parse_until_spec()?);
            until_span = Some(Span::new(start, self.tokens[self.pos - 1].span.end));
        }

        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Starting)) {
            self.advance();
            match self.peek().map(|t| &t.kind) {
                Some(TokenKind::IsoDate(d)) => {
                    let date = self.parse_iso_date(d)?;
                    self.advance();
                    schedule.anchor = Some(date);
                }
                _ => {
                    let span = self.current_span();
                    return Err(self.error(
                        "expected ISO date (YYYY-MM-DD) after 'starting'".into(),
                        span,
                    ));
                }
            }
        }

        // spec/README.md, "Named `until`": a month and day has no year of its own.
        if let (Some(UntilSpec::Named { month, day }), None, Some(span)) =
            (&schedule.until, schedule.anchor, until_span)
        {
            return Err(ScheduleError::parse(
                "a named until date needs a starting date to resolve its year (or use an ISO date)",
                span,
                self.input,
                Some(format!(
                    "until {} {day} starting YYYY-MM-DD",
                    month.as_str()
                )),
            ));
        }

        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::During)) {
            self.advance();
            schedule.during = self.parse_month_list()?;
        }

        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::In)) {
            self.advance();
            match self.peek().map(|t| &t.kind) {
                Some(TokenKind::Timezone(tz)) => {
                    schedule.timezone = Some(self.canonical_timezone(tz)?);
                    self.advance();
                }
                _ => {
                    let span = self.current_span();
                    return Err(self.error("expected timezone after 'in'".into(), span));
                }
            }
        }

        Ok(schedule)
    }

    fn parse_exception_list(&mut self) -> Result<Vec<Exception>, ScheduleError> {
        let mut exceptions = Vec::new();
        exceptions.push(self.parse_exception()?);

        while matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Comma)) {
            self.advance();
            exceptions.push(self.parse_exception()?);
        }

        Ok(exceptions)
    }

    fn parse_iso_date(&self, d: &str) -> Result<jiff::civil::Date, ScheduleError> {
        match d.parse::<jiff::civil::Date>() {
            Ok(date) if date.year() >= 1 => Ok(date),
            _ => Err(self.error(
                format!("invalid date: {d} (years run from 0001 to 9999)"),
                self.current_span(),
            )),
        }
    }

    /// spec/README.md, "Parse-time validation": `UTC` or an IANA Area/Location
    /// name in any case, stored with the database's capitalization.
    fn canonical_timezone(&self, name: &str) -> Result<String, ScheduleError> {
        let span = self.current_span();
        let lower = name.to_ascii_lowercase();
        // System zoneinfo directories that are not IANA names of their own.
        let legacy = ["systemv/", "posix/", "right/"]
            .iter()
            .any(|prefix| lower.starts_with(prefix));
        if !name.is_ascii() || legacy || (lower != "utc" && !name.contains('/')) {
            return Err(self.error(
                format!(
                    "unsupported timezone '{name}': use UTC or an IANA Area/Location name such as America/New_York"
                ),
                span,
            ));
        }
        // jiff answers `Etc/Unknown` with its placeholder zone rather than an error.
        match jiff::tz::TimeZone::get(name) {
            Ok(tz) if !tz.is_unknown() => match tz.iana_name() {
                Some(canonical) => Ok(canonical.to_string()),
                None => Err(self.unknown_timezone(name, span)),
            },
            _ => Err(self.unknown_timezone(name, span)),
        }
    }

    fn unknown_timezone(&self, name: &str, span: Span) -> ScheduleError {
        self.error(
            format!("unknown timezone '{name}': not in the IANA timezone database (check the spelling, e.g. America/New_York)"),
            span,
        )
    }

    fn parse_exception(&mut self) -> Result<Exception, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::IsoDate(d)) => {
                let d = d.clone();
                self.parse_iso_date(&d)?;
                self.advance();
                Ok(Exception::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let (day, day_span) = self.parse_day_number("after month name in exception")?;
                self.validate_named_date(month, day, day_span)?;
                Ok(Exception::Named { month, day })
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected ISO date or month-day in exception".into(), span))
            }
        }
    }

    fn parse_until_spec(&mut self) -> Result<UntilSpec, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::IsoDate(d)) => {
                let d = d.clone();
                self.parse_iso_date(&d)?;
                self.advance();
                Ok(UntilSpec::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let (day, day_span) = self.parse_day_number("after month name in until")?;
                self.validate_named_date(month, day, day_span)?;
                Ok(UntilSpec::Named { month, day })
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected ISO date or month-day after 'until'".into(), span))
            }
        }
    }

    fn parse_every(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        self.expect("repeater")?;

        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Year) => {
                self.advance();
                self.parse_year_repeat(1)
            }
            Some(TokenKind::Day) => self.parse_day_repeat(1, DayFilter::Every),
            Some(TokenKind::Weekday) => {
                self.advance();
                self.parse_day_repeat(1, DayFilter::Weekday)
            }
            Some(TokenKind::Weekend) => {
                self.advance();
                self.parse_day_repeat(1, DayFilter::Weekend)
            }
            Some(TokenKind::DayName(_)) => {
                let days = self.parse_day_list()?;
                self.parse_day_repeat(1, DayFilter::Days(days))
            }
            Some(TokenKind::Weeks) => {
                self.advance();
                self.parse_week_repeat(1)
            }
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(1)
            }
            Some(TokenKind::Number(_)) => self.parse_number_repeat(),
            _ => {
                let span = self.current_span();
                Err(self.error(
                    "expected day, weekday, weekend, week, year, day name, month, or number after 'every'"
                        .into(),
                    span,
                ))
            }
        }
    }

    // day_repeat: day_target already parsed (or "day" not yet consumed)
    fn parse_day_repeat(
        &mut self,
        interval: u32,
        days: DayFilter,
    ) -> Result<ScheduleExpr, ScheduleError> {
        if days == DayFilter::Every {
            self.consume_kind("'day'", |k| matches!(k, TokenKind::Day))?;
        }
        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        })
    }

    fn parse_number_repeat(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        let num = match &self.peek().unwrap().kind {
            TokenKind::Number(n) => *n,
            _ => unreachable!("parse_number_repeat called without Number token"),
        };
        if num == 0 || num > i32::MAX as u32 {
            let span = self.peek().unwrap().span;
            return Err(self.error(
                if num == 0 {
                    format!("interval must be at least 1 (allowed 1-{})", i32::MAX)
                } else {
                    format!("interval number too large (allowed 1-{})", i32::MAX)
                },
                span,
            ));
        }
        self.advance();

        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Weeks) => {
                self.advance();
                self.parse_week_repeat(num)
            }
            Some(TokenKind::IntervalUnit(_)) => self.parse_interval_repeat(num),
            Some(TokenKind::Day) => self.parse_day_repeat(num, DayFilter::Every),
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(num)
            }
            Some(TokenKind::Year) => {
                self.advance();
                self.parse_year_repeat(num)
            }
            _ => {
                let span = self.current_span();
                Err(self.error(
                    "expected 'weeks', 'days', 'months', 'years', 'min', 'minutes', 'hour', or 'hours' after number".into(),
                    span,
                ))
            }
        }
    }

    fn parse_interval_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        let unit_str = match &self.peek().unwrap().kind {
            TokenKind::IntervalUnit(u) => u.clone(),
            _ => unreachable!("parse_interval_repeat called without IntervalUnit token"),
        };
        self.advance();

        let unit = match unit_str.as_str() {
            "min" => IntervalUnit::Minutes,
            "hours" => IntervalUnit::Hours,
            _ => unreachable!("lexer produced invalid IntervalUnit: {unit_str}"),
        };

        self.consume_kind("'from'", |k| matches!(k, TokenKind::From))?;
        let from = self.parse_time()?;
        self.consume_kind("'to'", |k| matches!(k, TokenKind::To))?;
        let to_span = self.current_span();
        let to = self.parse_time()?;
        if from > to {
            return Err(self.error(
                format!(
                    "time range from {:02}:{:02} to {:02}:{:02} is reversed: a window cannot cross midnight, so 'from' must not be later than 'to'",
                    from.hour, from.minute, to.hour, to.minute
                ),
                to_span,
            ));
        }

        let day_filter = if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::On)) {
            self.advance();
            Some(self.parse_day_target()?)
        } else {
            None
        };

        Ok(ScheduleExpr::IntervalRepeat {
            interval,
            unit,
            from,
            to,
            day_filter,
        })
    }

    fn parse_week_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.consume_kind("'on'", |k| matches!(k, TokenKind::On))?;
        let days = self.parse_day_list()?;
        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;

        Ok(ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        })
    }

    fn parse_month_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.consume_kind("'on'", |k| matches!(k, TokenKind::On))?;
        self.consume_kind("'the'", |k| matches!(k, TokenKind::The))?;

        let target = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Last) => {
                self.advance();
                match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Day) => {
                        self.advance();
                        MonthTarget::LastDay
                    }
                    Some(TokenKind::Weekday) => {
                        self.advance();
                        MonthTarget::LastWeekday
                    }
                    Some(TokenKind::DayName(name)) => {
                        let weekday = parse_weekday(name).unwrap();
                        self.advance();
                        MonthTarget::OrdinalWeekday {
                            ordinal: OrdinalPosition::Last,
                            weekday,
                        }
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self.error(
                            "expected 'day', 'weekday', or day name after 'last'".into(),
                            span,
                        ));
                    }
                }
            }
            Some(TokenKind::Ordinal(_)) => {
                let ordinal = self.parse_ordinal_position()?;
                match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::DayName(name)) => {
                        let weekday = parse_weekday(name).unwrap();
                        self.advance();
                        MonthTarget::OrdinalWeekday { ordinal, weekday }
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self.error(
                            "expected day name after ordinal in monthly expression".into(),
                            span,
                        ));
                    }
                }
            }
            Some(TokenKind::OrdinalNumber(_)) => {
                let days = self.parse_ordinal_day_list()?;
                MonthTarget::Days(days)
            }
            Some(TokenKind::Next) | Some(TokenKind::Previous) | Some(TokenKind::Nearest) => {
                self.parse_nearest_weekday_target()?
            }
            _ => {
                let span = self.current_span();
                return Err(self.error(
                    "expected ordinal day (1st, 15th), 'last', ordinal (first, second, ...), or '[next|previous] nearest' after 'the'".into(),
                    span,
                ));
            }
        };

        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;

        Ok(ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        })
    }

    fn parse_nearest_weekday_target(&mut self) -> Result<MonthTarget, ScheduleError> {
        let direction = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Next) => {
                self.advance();
                Some(NearestDirection::Next)
            }
            Some(TokenKind::Previous) => {
                self.advance();
                Some(NearestDirection::Previous)
            }
            _ => None,
        };

        self.consume_kind("'nearest'", |k| matches!(k, TokenKind::Nearest))?;
        self.consume_kind("'weekday'", |k| matches!(k, TokenKind::Weekday))?;
        self.consume_kind("'to'", |k| matches!(k, TokenKind::To))?;

        let day = self.parse_ordinal_day_number()?;

        Ok(MonthTarget::NearestWeekday { day, direction })
    }

    fn parse_ordinal_day_number(&mut self) -> Result<u8, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::OrdinalNumber(n)) => {
                let d = self.validate_day_number(*n)?;
                self.advance();
                Ok(d)
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected ordinal day number".into(), span))
            }
        }
    }

    fn parse_year_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.consume_kind("'on'", |k| matches!(k, TokenKind::On))?;

        let target = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::The) => {
                self.advance();
                self.parse_year_target_after_the()?
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let (day, day_span) = self.parse_day_number("after month name")?;
                self.validate_named_date(month, day, day_span)?;
                YearTarget::Date { month, day }
            }
            _ => {
                let span = self.current_span();
                return Err(self.error(
                    "expected month name or 'the' after 'every year on'".into(),
                    span,
                ));
            }
        };

        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;

        Ok(ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        })
    }

    fn parse_year_target_after_the(&mut self) -> Result<YearTarget, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Last) => {
                self.advance();
                match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Weekday) => {
                        self.advance();
                        self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
                        let month = self.parse_month_name_token()?;
                        Ok(YearTarget::LastWeekday { month })
                    }
                    Some(TokenKind::DayName(name)) => {
                        let weekday = parse_weekday(name).unwrap();
                        self.advance();
                        self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
                        let month = self.parse_month_name_token()?;
                        Ok(YearTarget::OrdinalWeekday {
                            ordinal: OrdinalPosition::Last,
                            weekday,
                            month,
                        })
                    }
                    _ => {
                        let span = self.current_span();
                        Err(self.error(
                            "expected 'weekday' or day name after 'last' in yearly expression"
                                .into(),
                            span,
                        ))
                    }
                }
            }
            Some(TokenKind::Ordinal(_)) => {
                let ordinal = self.parse_ordinal_position()?;
                match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::DayName(name)) => {
                        let weekday = parse_weekday(name).unwrap();
                        self.advance();
                        self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
                        let month = self.parse_month_name_token()?;
                        Ok(YearTarget::OrdinalWeekday {
                            ordinal,
                            weekday,
                            month,
                        })
                    }
                    _ => {
                        let span = self.current_span();
                        Err(self.error(
                            "expected day name after ordinal in yearly expression".into(),
                            span,
                        ))
                    }
                }
            }
            Some(TokenKind::OrdinalNumber(n)) => {
                let day = self.validate_day_number(*n)?;
                let day_span = self.current_span();
                self.advance();
                self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
                let month = self.parse_month_name_token()?;
                self.validate_named_date(month, day, day_span)?;
                Ok(YearTarget::DayOfMonth { day, month })
            }
            _ => {
                let span = self.current_span();
                Err(self.error(
                    "expected ordinal, day number, or 'last' after 'the' in yearly expression"
                        .into(),
                    span,
                ))
            }
        }
    }

    fn parse_month_name_token(&mut self) -> Result<MonthName, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                Ok(month)
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected month name".into(), span))
            }
        }
    }

    fn parse_ordinal_position(&mut self) -> Result<OrdinalPosition, ScheduleError> {
        let span = self.current_span();
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Ordinal(s)) => {
                let pos = match s.as_str() {
                    "first" => OrdinalPosition::First,
                    "second" => OrdinalPosition::Second,
                    "third" => OrdinalPosition::Third,
                    "fourth" => OrdinalPosition::Fourth,
                    "fifth" => OrdinalPosition::Fifth,
                    _ => return Err(self.error(format!("unknown ordinal '{s}'"), span)),
                };
                self.advance();
                Ok(pos)
            }
            Some(TokenKind::Last) => {
                self.advance();
                Ok(OrdinalPosition::Last)
            }
            _ => Err(self.error(
                "expected ordinal (first, second, third, fourth, fifth, last)".into(),
                span,
            )),
        }
    }

    fn parse_on(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        let date = self.parse_date_target()?;
        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;

        Ok(ScheduleExpr::SingleDate { date, times })
    }

    fn parse_date_target(&mut self) -> Result<DateSpec, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::IsoDate(d)) => {
                let d = d.clone();
                self.parse_iso_date(&d)?;
                self.advance();
                Ok(DateSpec::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let (day, day_span) = self.parse_day_number("after month name")?;
                self.validate_named_date(month, day, day_span)?;
                Ok(DateSpec::Named { month, day })
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected date (ISO date or month name)".into(), span))
            }
        }
    }

    fn parse_day_target(&mut self) -> Result<DayFilter, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Day) => {
                self.advance();
                Ok(DayFilter::Every)
            }
            Some(TokenKind::Weekday) => {
                self.advance();
                Ok(DayFilter::Weekday)
            }
            Some(TokenKind::Weekend) => {
                self.advance();
                Ok(DayFilter::Weekend)
            }
            Some(TokenKind::DayName(_)) => {
                let days = self.parse_day_list()?;
                Ok(DayFilter::Days(days))
            }
            _ => {
                let span = self.current_span();
                Err(self.error(
                    "expected 'day', 'weekday', 'weekend', or day name".into(),
                    span,
                ))
            }
        }
    }

    fn parse_day_list(&mut self) -> Result<Vec<Weekday>, ScheduleError> {
        let mut days = Vec::new();
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::DayName(name)) => {
                days.push(parse_weekday(name).unwrap());
                self.advance();
            }
            _ => {
                let span = self.current_span();
                return Err(self.error("expected day name".into(), span));
            }
        }

        while matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Comma)) {
            self.advance(); // skip comma
            match self.peek().map(|t| &t.kind) {
                Some(TokenKind::DayName(name)) => {
                    days.push(parse_weekday(name).unwrap());
                    self.advance();
                }
                _ => {
                    let span = self.current_span();
                    return Err(self.error("expected day name after ','".into(), span));
                }
            }
        }

        Ok(days)
    }

    fn parse_ordinal_day_list(&mut self) -> Result<Vec<DayOfMonthSpec>, ScheduleError> {
        let mut specs = Vec::new();
        specs.push(self.parse_ordinal_day_spec()?);

        while matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Comma)) {
            self.advance(); // skip comma
            specs.push(self.parse_ordinal_day_spec()?);
        }

        Ok(specs)
    }

    fn parse_ordinal_day_spec(&mut self) -> Result<DayOfMonthSpec, ScheduleError> {
        let start = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::OrdinalNumber(n)) => {
                let d = self.validate_day_number(*n)?;
                self.advance();
                d
            }
            _ => {
                let span = self.current_span();
                return Err(self.error("expected ordinal day number".into(), span));
            }
        };

        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::To)) {
            self.advance(); // skip "to"
            let end = match self.peek().map(|t| &t.kind) {
                Some(TokenKind::OrdinalNumber(n)) => {
                    let d = self.validate_day_number(*n)?;
                    self.advance();
                    d
                }
                _ => {
                    let span = self.current_span();
                    return Err(self.error("expected ordinal day number after 'to'".into(), span));
                }
            };
            if start > end {
                let span = self.current_span();
                return Err(self.error(
                    format!(
                        "invalid day range: {} to {} (start must be <= end)",
                        start, end
                    ),
                    span,
                ));
            }
            Ok(DayOfMonthSpec::Range(start, end))
        } else {
            Ok(DayOfMonthSpec::Single(start))
        }
    }

    fn parse_month_list(&mut self) -> Result<Vec<MonthName>, ScheduleError> {
        let mut months = vec![self.parse_month_name_token()?];
        while matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Comma)) {
            self.advance();
            months.push(self.parse_month_name_token()?);
        }
        Ok(months)
    }

    fn parse_time_list(&mut self) -> Result<Vec<TimeOfDay>, ScheduleError> {
        let mut times = vec![self.parse_time()?];
        while matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Comma)) {
            self.advance();
            times.push(self.parse_time()?);
        }
        Ok(times)
    }

    fn parse_time(&mut self) -> Result<TimeOfDay, ScheduleError> {
        let span = self.current_span();
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Time(h, m)) => {
                let time = TimeOfDay {
                    hour: *h,
                    minute: *m,
                };
                self.advance();
                Ok(time)
            }
            _ => Err(self.error("expected time (HH:MM)".into(), span)),
        }
    }
}

pub fn parse(input: &str) -> Result<Schedule, ScheduleError> {
    let mut lexer = crate::lexer::Lexer::new(input);
    let tokens = lexer.tokenize()?;

    if tokens.is_empty() {
        return Err(ScheduleError::parse(
            "empty expression",
            Span::new(0, 0),
            input,
            None,
        ));
    }

    let mut parser = Parser::new(&tokens, input);
    let schedule = parser.parse_expression()?;

    if parser.peek().is_some() {
        let span = parser.current_span();
        return Err(ScheduleError::parse(
            "unexpected tokens after expression",
            span,
            input,
            None,
        ));
    }

    Ok(schedule)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_every_day() {
        let s = parse("every day at 09:00").unwrap();
        match &s.expr {
            ScheduleExpr::DayRepeat { days, times, .. } => {
                assert_eq!(*days, DayFilter::Every);
                assert_eq!(*times, vec![TimeOfDay { hour: 9, minute: 0 }]);
            }
            _ => panic!("expected DayRepeat"),
        }
        assert_eq!(s.timezone, None);
    }

    #[test]
    fn test_parse_every_weekday() {
        let s = parse("every weekday at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::DayRepeat { days, .. } => assert_eq!(*days, DayFilter::Weekday),
            _ => panic!("expected DayRepeat"),
        }
    }

    #[test]
    fn test_parse_every_weekend() {
        let s = parse("every weekend at 10:00").unwrap();
        match &s.expr {
            ScheduleExpr::DayRepeat { days, .. } => assert_eq!(*days, DayFilter::Weekend),
            _ => panic!("expected DayRepeat"),
        }
    }

    #[test]
    fn test_parse_specific_days() {
        let s = parse("every mon, wed, fri at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::DayRepeat {
                days: DayFilter::Days(days),
                ..
            } => {
                assert_eq!(
                    *days,
                    vec![Weekday::Monday, Weekday::Wednesday, Weekday::Friday]
                );
            }
            _ => panic!("expected DayRepeat with Days"),
        }
    }

    #[test]
    fn test_parse_interval() {
        let s = parse("every 30 min from 09:00 to 17:00").unwrap();
        match &s.expr {
            ScheduleExpr::IntervalRepeat {
                interval,
                unit,
                from,
                to,
                day_filter,
            } => {
                assert_eq!(*interval, 30);
                assert_eq!(*unit, IntervalUnit::Minutes);
                assert_eq!(*from, TimeOfDay { hour: 9, minute: 0 });
                assert_eq!(
                    *to,
                    TimeOfDay {
                        hour: 17,
                        minute: 0
                    }
                );
                assert_eq!(*day_filter, None);
            }
            _ => panic!("expected IntervalRepeat"),
        }
    }

    #[test]
    fn test_parse_interval_with_day_filter() {
        let s = parse("every 45 min from 09:00 to 17:00 on weekdays").unwrap();
        match &s.expr {
            ScheduleExpr::IntervalRepeat { day_filter, .. } => {
                assert_eq!(*day_filter, Some(DayFilter::Weekday));
            }
            _ => panic!("expected IntervalRepeat"),
        }
    }

    #[test]
    fn test_parse_week_repeat() {
        let s = parse("every 2 weeks on monday at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::WeekRepeat { interval, days, .. } => {
                assert_eq!(*interval, 2);
                assert_eq!(*days, vec![Weekday::Monday]);
            }
            _ => panic!("expected WeekRepeat"),
        }
    }

    #[test]
    fn test_parse_month_repeat() {
        let s = parse("every month on the 1st at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, .. } => {
                assert_eq!(*target, MonthTarget::Days(vec![DayOfMonthSpec::Single(1)]));
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_month_repeat_multiple() {
        let s = parse("every month on the 1st, 15th at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, .. } => {
                assert_eq!(
                    *target,
                    MonthTarget::Days(vec![DayOfMonthSpec::Single(1), DayOfMonthSpec::Single(15)])
                );
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_month_last_day() {
        let s = parse("every month on the last day at 17:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, .. } => {
                assert_eq!(*target, MonthTarget::LastDay);
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_month_last_weekday() {
        let s = parse("every month on the last weekday at 15:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, .. } => {
                assert_eq!(*target, MonthTarget::LastWeekday);
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_ordinal_weekday() {
        let s = parse("every month on the first monday at 10:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, times, .. } => {
                assert_eq!(
                    *target,
                    MonthTarget::OrdinalWeekday {
                        ordinal: OrdinalPosition::First,
                        weekday: Weekday::Monday,
                    }
                );
                assert_eq!(
                    *times,
                    vec![TimeOfDay {
                        hour: 10,
                        minute: 0
                    }]
                );
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_last_weekday_name() {
        let s = parse("every month on the last friday at 16:00").unwrap();
        match &s.expr {
            ScheduleExpr::MonthRepeat { target, .. } => {
                assert_eq!(
                    *target,
                    MonthTarget::OrdinalWeekday {
                        ordinal: OrdinalPosition::Last,
                        weekday: Weekday::Friday,
                    }
                );
            }
            _ => panic!("expected MonthRepeat"),
        }
    }

    #[test]
    fn test_parse_single_date_named() {
        let s = parse("on feb 14 at 9:00").unwrap();
        match &s.expr {
            ScheduleExpr::SingleDate { date, .. } => {
                assert_eq!(
                    *date,
                    DateSpec::Named {
                        month: MonthName::February,
                        day: 14
                    }
                );
            }
            _ => panic!("expected SingleDate"),
        }
    }

    #[test]
    fn test_parse_single_date_iso() {
        let s = parse("on 2026-03-15 at 14:30").unwrap();
        match &s.expr {
            ScheduleExpr::SingleDate { date, times } => {
                assert_eq!(*date, DateSpec::Iso("2026-03-15".into()));
                assert_eq!(
                    *times,
                    vec![TimeOfDay {
                        hour: 14,
                        minute: 30
                    }]
                );
            }
            _ => panic!("expected SingleDate"),
        }
    }

    #[test]
    fn test_parse_with_timezone() {
        let s = parse("every weekday at 9:00 in America/Vancouver").unwrap();
        assert_eq!(s.timezone, Some("America/Vancouver".into()));
    }

    #[test]
    fn test_parse_except_named() {
        let s = parse("every weekday at 9:00 except dec 25, jan 1").unwrap();
        assert_eq!(s.except.len(), 2);
        assert_eq!(
            s.except[0],
            Exception::Named {
                month: MonthName::December,
                day: 25
            }
        );
        assert_eq!(
            s.except[1],
            Exception::Named {
                month: MonthName::January,
                day: 1
            }
        );
    }

    #[test]
    fn test_parse_except_iso() {
        let s = parse("every weekday at 9:00 except 2026-12-25").unwrap();
        assert_eq!(s.except.len(), 1);
        assert_eq!(s.except[0], Exception::Iso("2026-12-25".into()));
    }

    #[test]
    fn test_parse_until_iso() {
        let s = parse("every day at 09:00 until 2026-12-31").unwrap();
        assert_eq!(s.until, Some(UntilSpec::Iso("2026-12-31".into())));
    }

    #[test]
    fn test_parse_until_named() {
        let s = parse("every day at 09:00 until dec 31 starting 2026-01-01").unwrap();
        assert_eq!(
            s.until,
            Some(UntilSpec::Named {
                month: MonthName::December,
                day: 31
            })
        );
    }

    #[test]
    fn test_parse_starting() {
        let s = parse("every 2 weeks on monday at 9:00 starting 2026-01-05").unwrap();
        assert_eq!(s.anchor, Some(jiff::civil::Date::new(2026, 1, 5).unwrap()));
    }

    #[test]
    fn test_parse_year_repeat_date() {
        let s = parse("every year on dec 25 at 00:00").unwrap();
        match &s.expr {
            ScheduleExpr::YearRepeat { target, times, .. } => {
                assert_eq!(
                    *target,
                    YearTarget::Date {
                        month: MonthName::December,
                        day: 25
                    }
                );
                assert_eq!(*times, vec![TimeOfDay { hour: 0, minute: 0 }]);
            }
            _ => panic!("expected YearRepeat"),
        }
    }

    #[test]
    fn test_parse_year_repeat_ordinal_weekday() {
        let s = parse("every year on the first monday of march at 10:00").unwrap();
        match &s.expr {
            ScheduleExpr::YearRepeat { target, .. } => {
                assert_eq!(
                    *target,
                    YearTarget::OrdinalWeekday {
                        ordinal: OrdinalPosition::First,
                        weekday: Weekday::Monday,
                        month: MonthName::March,
                    }
                );
            }
            _ => panic!("expected YearRepeat"),
        }
    }

    #[test]
    fn test_parse_year_repeat_day_of_month() {
        let s = parse("every year on the 15th of march at 09:00").unwrap();
        match &s.expr {
            ScheduleExpr::YearRepeat { target, .. } => {
                assert_eq!(
                    *target,
                    YearTarget::DayOfMonth {
                        day: 15,
                        month: MonthName::March
                    }
                );
            }
            _ => panic!("expected YearRepeat"),
        }
    }

    #[test]
    fn test_parse_year_repeat_last_weekday() {
        let s = parse("every year on the last weekday of december at 17:00").unwrap();
        match &s.expr {
            ScheduleExpr::YearRepeat { target, .. } => {
                assert_eq!(
                    *target,
                    YearTarget::LastWeekday {
                        month: MonthName::December
                    }
                );
            }
            _ => panic!("expected YearRepeat"),
        }
    }

    #[test]
    fn test_parse_all_clauses() {
        let s = parse(
            "every weekday at 9:00 except dec 25 until 2027-12-31 starting 2026-01-01 in UTC",
        )
        .unwrap();
        assert_eq!(s.except.len(), 1);
        assert_eq!(s.until, Some(UntilSpec::Iso("2027-12-31".into())));
        assert_eq!(s.anchor, Some(jiff::civil::Date::new(2026, 1, 1).unwrap()));
        assert_eq!(s.timezone, Some("UTC".into()));
    }

    #[test]
    fn test_error_on_empty() {
        assert!(parse("").is_err());
    }

    #[test]
    fn test_error_on_garbage() {
        assert!(parse("hello world").is_err());
    }
}
