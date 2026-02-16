// Hand-rolled recursive descent parser for hron expressions.
// Follows the grammar defined in /spec/grammar.ebnf (repo root).

use crate::ast::*;
use crate::error::{ScheduleError, Span};
use crate::lexer::{Token, TokenKind};

/// Parser state: consumes a slice of tokens.
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

    // --- Grammar productions ---

    // expression = every_expr | on_expr | ordinal_repeat
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
            // ordinal_repeat: "first monday of every month at 10:00"
            Some(TokenKind::Ordinal(_)) => self.parse_ordinal_repeat()?,
            // "last" can start ordinal_repeat too
            Some(TokenKind::Last) => self.parse_ordinal_repeat()?,
            _ => {
                return Err(self.error(
                    "expected 'every', 'on', or an ordinal (first, second, ...)".into(),
                    span,
                ));
            }
        };

        // Parse trailing clauses: except, until, starting, timezone
        self.parse_trailing_clauses(expr)
    }

    /// Parse trailing clauses in order: except → until → starting → timezone.
    /// Each is optional, but `in` must be last.
    fn parse_trailing_clauses(&mut self, expr: ScheduleExpr) -> Result<Schedule, ScheduleError> {
        let mut schedule = Schedule::new(expr);

        // except <date>, ...
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Except)) {
            self.advance();
            schedule.except = self.parse_exception_list()?;
        }

        // until <date>
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Until)) {
            self.advance();
            schedule.until = Some(self.parse_until_spec()?);
        }

        // starting <iso-date>
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::Starting)) {
            self.advance();
            match self.peek().map(|t| &t.kind) {
                Some(TokenKind::IsoDate(d)) => {
                    let date: jiff::civil::Date = d.parse().map_err(|e| {
                        self.error(format!("invalid starting date: {e}"), self.current_span())
                    })?;
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

        // during <month_list>
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::During)) {
            self.advance();
            schedule.during = self.parse_month_list()?;
        }

        // in <timezone>
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::In)) {
            self.advance();
            match self.peek().map(|t| &t.kind) {
                Some(TokenKind::Timezone(tz)) => {
                    schedule.timezone = Some(tz.clone());
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

    fn validate_iso_date(&self, d: &str) -> Result<(), ScheduleError> {
        d.parse::<jiff::civil::Date>()
            .map_err(|_| self.error(format!("invalid date: {d}"), self.current_span()))?;
        Ok(())
    }

    fn parse_exception(&mut self) -> Result<Exception, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            Some(TokenKind::IsoDate(d)) => {
                let d = d.clone();
                self.validate_iso_date(&d)?;
                self.advance();
                Ok(Exception::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let day = match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Number(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    Some(TokenKind::OrdinalNumber(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self.error(
                            "expected day number after month name in exception".into(),
                            span,
                        ));
                    }
                };
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
                self.validate_iso_date(&d)?;
                self.advance();
                Ok(UntilSpec::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let day = match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Number(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    Some(TokenKind::OrdinalNumber(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self
                            .error("expected day number after month name in until".into(), span));
                    }
                };
                Ok(UntilSpec::Named { month, day })
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected ISO date or month-day after 'until'".into(), span))
            }
        }
    }

    // After "every": dispatch on next token
    fn parse_every(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        self.expect("repeater")?;

        match self.peek().map(|t| &t.kind) {
            // "every year on ..."
            Some(TokenKind::Year) => {
                self.advance();
                self.parse_year_repeat(1)
            }
            // "every day at ..."
            Some(TokenKind::Day) => self.parse_day_repeat(1, DayFilter::Every),
            // "every weekday at ..."
            Some(TokenKind::Weekday) => {
                self.advance();
                self.parse_day_repeat(1, DayFilter::Weekday)
            }
            // "every weekend at ..."
            Some(TokenKind::Weekend) => {
                self.advance();
                self.parse_day_repeat(1, DayFilter::Weekend)
            }
            // "every monday ..." or "every monday, wednesday, friday at ..."
            Some(TokenKind::DayName(_)) => {
                let days = self.parse_day_list()?;
                self.parse_day_repeat(1, DayFilter::Days(days))
            }
            // "every month on ..."
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(1)
            }
            // "every N ..." — could be interval or week repeat
            Some(TokenKind::Number(_)) => self.parse_number_repeat(),
            _ => {
                let span = self.current_span();
                Err(self.error(
                    "expected day, weekday, weekend, year, day name, month, or number after 'every'"
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
        // If days is Every, consume the "day" token
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

    // After "every N": dispatch to interval_repeat, week_repeat, day_repeat, month_repeat, or year_repeat
    fn parse_number_repeat(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        let num = match &self.peek().unwrap().kind {
            TokenKind::Number(n) => *n,
            _ => unreachable!("parse_number_repeat called without Number token"),
        };
        if num == 0 {
            let span = self.peek().unwrap().span;
            return Err(self.error("interval must be at least 1".into(), span));
        }
        self.advance();

        match self.peek().map(|t| &t.kind) {
            // "every N weeks on ..."
            Some(TokenKind::Weeks) => {
                self.advance();
                self.parse_week_repeat(num)
            }
            // "every N min/hours from ..."
            Some(TokenKind::IntervalUnit(_)) => self.parse_interval_repeat(num),
            // "every N days at ..." / "every N day at ..."
            Some(TokenKind::Day) => self.parse_day_repeat(num, DayFilter::Every),
            // "every N months on ..." / "every N month on ..."
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(num)
            }
            // "every N years on ..." / "every N year on ..."
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

    // interval_repeat: "every [N] unit from HH:MM to HH:MM [on day_target]"
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
        let to = self.parse_time()?;

        // Optional "on day_target"
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

    // week_repeat: "every N weeks on day_list at HH:MM[, HH:MM]"
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

    // month_repeat: "[N] month[s] on the (ordinal_days | last day | last weekday | [direction] nearest weekday to day) at HH:MM"
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
                    _ => {
                        let span = self.current_span();
                        return Err(
                            self.error("expected 'day' or 'weekday' after 'last'".into(), span)
                        );
                    }
                }
            }
            Some(TokenKind::OrdinalNumber(_)) => {
                let days = self.parse_ordinal_day_list()?;
                MonthTarget::Days(days)
            }
            // [next|previous] nearest weekday to <day>
            Some(TokenKind::Next) | Some(TokenKind::Previous) | Some(TokenKind::Nearest) => {
                self.parse_nearest_weekday_target()?
            }
            _ => {
                let span = self.current_span();
                return Err(self.error(
                    "expected ordinal day (1st, 15th), 'last', or '[next|previous] nearest' after 'the'".into(),
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

    // [next|previous] nearest weekday to <day>
    fn parse_nearest_weekday_target(&mut self) -> Result<MonthTarget, ScheduleError> {
        // Optional direction: "next" or "previous"
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
                let d = *n as u8;
                self.advance();
                Ok(d)
            }
            _ => {
                let span = self.current_span();
                Err(self.error("expected ordinal day number".into(), span))
            }
        }
    }

    // ordinal_repeat: "first monday of every [N] month[s] at HH:MM"
    fn parse_ordinal_repeat(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        let ordinal = self.parse_ordinal_position()?;

        let day_name = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::DayName(name)) => {
                let d = parse_weekday(name).unwrap();
                self.advance();
                d
            }
            _ => {
                let span = self.current_span();
                return Err(self.error("expected day name after ordinal".into(), span));
            }
        };

        self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
        self.consume_kind("'every'", |k| matches!(k, TokenKind::Every))?;

        // Optional interval: "of every 2 months" vs "of every month"
        let interval = match self.peek().map(|t| &t.kind) {
            Some(TokenKind::Number(n)) => {
                let n = *n;
                if n == 0 {
                    let span = self.peek().unwrap().span;
                    return Err(self.error("interval must be at least 1".into(), span));
                }
                self.advance();
                n
            }
            _ => 1,
        };

        self.consume_kind("'month'", |k| matches!(k, TokenKind::Month))?;
        self.consume_kind("'at'", |k| matches!(k, TokenKind::At))?;
        let times = self.parse_time_list()?;

        Ok(ScheduleExpr::OrdinalRepeat {
            interval,
            ordinal,
            day: day_name,
            times,
        })
    }

    // year_repeat: "every [N] year[s] on <year_target> at HH:MM"
    fn parse_year_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.consume_kind("'on'", |k| matches!(k, TokenKind::On))?;

        let target = match self.peek().map(|t| &t.kind) {
            // "on the ..." — ordinal weekday, day of month, or last weekday
            Some(TokenKind::The) => {
                self.advance();
                self.parse_year_target_after_the()?
            }
            // "on dec 25" — direct month+day
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let day = match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Number(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    Some(TokenKind::OrdinalNumber(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self.error("expected day number after month name".into(), span));
                    }
                };
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

    // After "every year on the": parse ordinal weekday, day of month, or last weekday
    fn parse_year_target_after_the(&mut self) -> Result<YearTarget, ScheduleError> {
        match self.peek().map(|t| &t.kind) {
            // "the last weekday of <month>" or "the last friday of <month>"
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
            // "the first monday of march" or "the 15th of march"
            Some(TokenKind::Ordinal(_)) => {
                let ordinal = self.parse_ordinal_position()?;
                // Next must be a day name
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
                let day = *n as u8;
                self.advance();
                self.consume_kind("'of'", |k| matches!(k, TokenKind::Of))?;
                let month = self.parse_month_name_token()?;
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

    // on_expr: "on date_target at HH:MM[, HH:MM]"
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
                self.validate_iso_date(&d)?;
                self.advance();
                Ok(DateSpec::Iso(d))
            }
            Some(TokenKind::MonthName(m)) => {
                let month = parse_month_name(m).unwrap();
                self.advance();
                let day = match self.peek().map(|t| &t.kind) {
                    Some(TokenKind::Number(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    Some(TokenKind::OrdinalNumber(n)) => {
                        let d = *n as u8;
                        self.advance();
                        d
                    }
                    _ => {
                        let span = self.current_span();
                        return Err(self.error("expected day number after month name".into(), span));
                    }
                };
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
                let d = *n as u8;
                self.advance();
                d
            }
            _ => {
                let span = self.current_span();
                return Err(self.error("expected ordinal day number".into(), span));
            }
        };

        // Check for range: "1st to 15th"
        if matches!(self.peek().map(|t| &t.kind), Some(TokenKind::To)) {
            self.advance(); // skip "to"
            let end = match self.peek().map(|t| &t.kind) {
                Some(TokenKind::OrdinalNumber(n)) => {
                    let d = *n as u8;
                    self.advance();
                    d
                }
                _ => {
                    let span = self.current_span();
                    return Err(self.error("expected ordinal day number after 'to'".into(), span));
                }
            };
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

/// Parse an hron expression string into a Schedule AST.
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

    // Ensure all tokens consumed
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
    fn test_parse_ordinal_repeat() {
        let s = parse("first monday of every month at 10:00").unwrap();
        match &s.expr {
            ScheduleExpr::OrdinalRepeat {
                ordinal,
                day,
                times,
                ..
            } => {
                assert_eq!(*ordinal, OrdinalPosition::First);
                assert_eq!(*day, Weekday::Monday);
                assert_eq!(
                    *times,
                    vec![TimeOfDay {
                        hour: 10,
                        minute: 0
                    }]
                );
            }
            _ => panic!("expected OrdinalRepeat"),
        }
    }

    #[test]
    fn test_parse_last_ordinal() {
        let s = parse("last friday of every month at 16:00").unwrap();
        match &s.expr {
            ScheduleExpr::OrdinalRepeat { ordinal, day, .. } => {
                assert_eq!(*ordinal, OrdinalPosition::Last);
                assert_eq!(*day, Weekday::Friday);
            }
            _ => panic!("expected OrdinalRepeat"),
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
        let s = parse("every day at 09:00 until dec 31").unwrap();
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
