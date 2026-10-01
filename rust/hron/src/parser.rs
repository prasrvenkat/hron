// Recursive descent parser for spec/grammar.ebnf.

use crate::ast::*;
use crate::error::{ScheduleError, Span};
use crate::lexer::{Lexer, Token, TokenKind};

/// The `{what}` of each `expected {what}, got ...` error, one per phrase in
/// the position table of spec/README.md, "Parse errors".
mod expected {
    pub const EVERY_OR_ON: &str = "'every' or 'on'";
    pub const REPEATER: &str =
        "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number";
    pub const UNIT: &str = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')";
    pub const AT: &str = "'at'";
    pub const TIME: &str = "a time (HH:MM)";
    pub const FROM: &str = "'from'";
    pub const TO: &str = "'to'";
    pub const DAY_TARGET: &str = "'day', 'weekday', 'weekend' or a day name";
    pub const ON: &str = "'on'";
    pub const DAY_NAME: &str = "a day name";
    pub const THE: &str = "'the'";
    pub const MONTH_TARGET: &str =
        "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'";
    pub const MONTH_LAST: &str = "'day', 'weekday' or a day name";
    pub const NEAREST: &str = "'nearest'";
    pub const WEEKDAY: &str = "'weekday'";
    pub const DAY_OF_MONTH: &str = "a day such as 15th";
    pub const YEAR_TARGET: &str = "a month name or 'the'";
    pub const YEAR_THE: &str = "a day such as 15th, 'last' or an ordinal such as 'first'";
    pub const YEAR_LAST: &str = "'weekday' or a day name";
    pub const OF: &str = "'of'";
    pub const MONTH_NAME: &str = "a month name";
    pub const DAY_NUMBER: &str = "a day number";
    pub const DATE: &str = "a date (YYYY-MM-DD, or a month and day)";
    pub const ISO_DATE: &str = "a date (YYYY-MM-DD)";
    pub const TIMEZONE: &str = "a timezone";
}

const CLAUSE_ORDER: [(TokenKind, &str); 5] = [
    (TokenKind::Except, "except"),
    (TokenKind::Until, "until"),
    (TokenKind::Starting, "starting"),
    (TokenKind::During, "during"),
    (TokenKind::In, "in"),
];

struct Parser<'a> {
    tokens: &'a [Token],
    pos: usize,
    input: &'a str,
    until_bytes: Option<(usize, usize)>,
}

impl<'a> Parser<'a> {
    fn peek(&self) -> Option<&'a Token> {
        self.tokens.get(self.pos)
    }

    fn peek_kind(&self) -> Option<&'a TokenKind> {
        self.peek().map(|t| &t.kind)
    }

    fn advance(&mut self) -> &'a Token {
        let token = &self.tokens[self.pos];
        self.pos += 1;
        token
    }

    fn previous(&self) -> &'a Token {
        &self.tokens[self.pos - 1]
    }

    fn eat(&mut self, kind: &TokenKind) -> bool {
        let found = self.peek_kind() == Some(kind);
        if found {
            self.pos += 1;
        }
        found
    }

    fn expect(&mut self, kind: &TokenKind, what: &str) -> Result<(), ScheduleError> {
        if self.eat(kind) {
            Ok(())
        } else {
            Err(self.expected(what))
        }
    }

    fn text(&self, token: &Token) -> &'a str {
        &self.input[token.start..token.end]
    }

    fn error(&self, message: String, start: usize, end: usize) -> ScheduleError {
        let span = Span::from_byte_range(self.input, start, end);
        ScheduleError::parse(message, span, self.input, None)
    }

    fn expected(&self, what: &str) -> ScheduleError {
        match self.peek() {
            Some(token) => self.error(
                format!("expected {what}, got '{}'", self.text(token)),
                token.start,
                token.end,
            ),
            None => {
                let end = self.tokens.last().map_or(0, |t| t.end);
                self.error(format!("expected {what}, got end of input"), end, end)
            }
        }
    }

    fn parse_expression(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        match self.peek_kind() {
            Some(TokenKind::Every) => {
                self.advance();
                self.parse_every()
            }
            Some(TokenKind::On) => {
                self.advance();
                self.parse_on()
            }
            _ => Err(self.expected(expected::EVERY_OR_ON)),
        }
    }

    fn parse_clauses(&mut self, expr: ScheduleExpr) -> Result<Schedule, ScheduleError> {
        let mut schedule = Schedule::new(expr);

        if self.eat(&TokenKind::Except) {
            schedule.except = self.parse_exception_list()?;
        }

        if self.peek_kind() == Some(&TokenKind::Until) {
            let until = self.advance();
            schedule.until = Some(match self.parse_date()? {
                DateSpec::Iso(date) => UntilSpec::Iso(date),
                DateSpec::Named { month, day } => UntilSpec::Named { month, day },
            });
            self.until_bytes = Some((until.start, self.previous().end));
        }

        if self.eat(&TokenKind::Starting) {
            if self.peek_kind() != Some(&TokenKind::IsoDate) {
                return Err(self.expected(expected::ISO_DATE));
            }
            let token = self.advance();
            schedule.anchor = Some(self.iso_date(token)?);
        }

        if self.eat(&TokenKind::During) {
            schedule.during = self.parse_month_list()?;
        }

        if self.eat(&TokenKind::In) {
            if self.peek_kind() != Some(&TokenKind::Timezone) {
                return Err(self.expected(expected::TIMEZONE));
            }
            let token = self.advance();
            schedule.timezone = Some(self.timezone(token)?);
        }

        Ok(schedule)
    }

    fn leftover(&self, schedule: &Schedule) -> ScheduleError {
        let token = &self.tokens[self.pos];
        // Every clause holds at least one item, so a clause was read exactly when its field is set.
        let read = [
            !schedule.except.is_empty(),
            schedule.until.is_some(),
            schedule.anchor.is_some(),
            !schedule.during.is_empty(),
            schedule.timezone.is_some(),
        ];
        let clause = CLAUSE_ORDER
            .iter()
            .position(|(kind, _)| *kind == token.kind);
        let last_read = read.iter().rposition(|&was_read| was_read);
        let message = match (clause, last_read) {
            (Some(i), _) if read[i] => format!("duplicate '{}' clause", CLAUSE_ORDER[i].1),
            (Some(i), Some(last)) => format!(
                "'{}' must come before '{}'",
                CLAUSE_ORDER[i].1, CLAUSE_ORDER[last].1
            ),
            _ => format!("unexpected '{}' after the schedule", self.text(token)),
        };
        self.error(message, token.start, token.end)
    }

    fn check_named_until(&self, schedule: &Schedule) -> Result<(), ScheduleError> {
        if let (Some(UntilSpec::Named { month, day }), None, Some((start, end))) =
            (&schedule.until, schedule.anchor, self.until_bytes)
        {
            let month = month.as_str();
            return Err(ScheduleError::parse(
                format!("until {month} {day} has no year: add a starting date, or use an ISO date"),
                Span::from_byte_range(self.input, start, end),
                self.input,
                Some(format!("until {month} {day} starting YYYY-MM-DD")),
            ));
        }
        Ok(())
    }

    fn parse_exception_list(&mut self) -> Result<Vec<Exception>, ScheduleError> {
        let mut exceptions = vec![self.parse_exception()?];
        while self.eat(&TokenKind::Comma) {
            exceptions.push(self.parse_exception()?);
        }
        Ok(exceptions)
    }

    fn parse_exception(&mut self) -> Result<Exception, ScheduleError> {
        Ok(match self.parse_date()? {
            DateSpec::Iso(date) => Exception::Iso(date),
            DateSpec::Named { month, day } => Exception::Named { month, day },
        })
    }

    fn parse_date(&mut self) -> Result<DateSpec, ScheduleError> {
        match self.peek_kind() {
            Some(TokenKind::IsoDate) => {
                let token = self.advance();
                self.iso_date(token)?;
                Ok(DateSpec::Iso(self.text(token).to_string()))
            }
            Some(&TokenKind::MonthName(month)) => {
                self.advance();
                let day = self.parse_day_of(month)?;
                Ok(DateSpec::Named { month, day })
            }
            _ => Err(self.expected(expected::DATE)),
        }
    }

    fn iso_date(&self, token: &Token) -> Result<jiff::civil::Date, ScheduleError> {
        match self.text(token).parse::<jiff::civil::Date>() {
            Ok(date) if date.year() >= 1 => Ok(date),
            _ => Err(self.error(
                format!(
                    "date must be a calendar date from 0001-01-01 to 9999-12-31, got {}",
                    self.text(token)
                ),
                token.start,
                token.end,
            )),
        }
    }

    /// spec/README.md, "Parse-time validation": `UTC` or an IANA Area/Location
    /// name in any case, stored with the database's capitalization.
    fn timezone(&self, token: &Token) -> Result<String, ScheduleError> {
        let name = self.text(token);
        let lower = name.to_ascii_lowercase();
        // System zoneinfo directories that are not IANA names of their own.
        let legacy = ["systemv/", "posix/", "right/"]
            .iter()
            .any(|prefix| lower.starts_with(prefix));
        let shaped = name.is_ascii() && !legacy && (lower == "utc" || name.contains('/'));
        // jiff answers `Etc/Unknown` with its placeholder zone rather than an error.
        let canonical = shaped
            .then(|| jiff::tz::TimeZone::get(name).ok())
            .flatten()
            .filter(|tz| !tz.is_unknown())
            .and_then(|tz| tz.iana_name().map(str::to_string));
        canonical.ok_or_else(|| {
            self.error(
                format!("timezone must be UTC or an Area/Location name such as America/New_York, got {name}"),
                token.start,
                token.end,
            )
        })
    }

    fn parse_every(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        match self.peek_kind() {
            Some(TokenKind::Day) => {
                self.advance();
                self.parse_day_repeat(1, DayFilter::Every)
            }
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
            Some(TokenKind::Week) => {
                self.advance();
                self.parse_week_repeat(1)
            }
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(1)
            }
            Some(TokenKind::Year) => {
                self.advance();
                self.parse_year_repeat(1)
            }
            Some(&TokenKind::Number(interval)) => self.parse_number_repeat(interval),
            _ => Err(self.expected(expected::REPEATER)),
        }
    }

    fn parse_day_repeat(
        &mut self,
        interval: u32,
        days: DayFilter,
    ) -> Result<ScheduleExpr, ScheduleError> {
        self.expect(&TokenKind::At, expected::AT)?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::DayRepeat {
            interval,
            days,
            times,
        })
    }

    fn parse_number_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        let number = self.advance();
        if interval == 0 {
            return Err(self.error(
                format!("interval must be 1-2147483647, got {}", self.text(number)),
                number.start,
                number.end,
            ));
        }

        match self.peek_kind() {
            Some(TokenKind::Week) => {
                self.advance();
                self.parse_week_repeat(interval)
            }
            Some(&TokenKind::IntervalUnit(unit)) => {
                self.advance();
                self.parse_interval_repeat(interval, unit)
            }
            Some(TokenKind::Day) => {
                self.advance();
                self.parse_day_repeat(interval, DayFilter::Every)
            }
            Some(TokenKind::Month) => {
                self.advance();
                self.parse_month_repeat(interval)
            }
            Some(TokenKind::Year) => {
                self.advance();
                self.parse_year_repeat(interval)
            }
            _ => Err(self.expected(expected::UNIT)),
        }
    }

    fn parse_interval_repeat(
        &mut self,
        interval: u32,
        unit: IntervalUnit,
    ) -> Result<ScheduleExpr, ScheduleError> {
        self.expect(&TokenKind::From, expected::FROM)?;
        let from = self.parse_time()?;
        let from_token = self.previous();
        self.expect(&TokenKind::To, expected::TO)?;
        let to = self.parse_time()?;
        let to_token = self.previous();
        if from > to {
            return Err(self.error(
                format!(
                    "time window must not run backwards: {} to {} (a window cannot cross midnight)",
                    self.text(from_token),
                    self.text(to_token)
                ),
                from_token.start,
                to_token.end,
            ));
        }

        let day_filter = if self.eat(&TokenKind::On) {
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
        self.expect(&TokenKind::On, expected::ON)?;
        let days = self.parse_day_list()?;
        self.expect(&TokenKind::At, expected::AT)?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::WeekRepeat {
            interval,
            days,
            times,
        })
    }

    fn parse_month_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.expect(&TokenKind::On, expected::ON)?;
        self.expect(&TokenKind::The, expected::THE)?;

        let target = match self.peek_kind() {
            Some(TokenKind::Last) => {
                self.advance();
                let target = match self.peek_kind() {
                    Some(TokenKind::Day) => MonthTarget::LastDay,
                    Some(TokenKind::Weekday) => MonthTarget::LastWeekday,
                    Some(&TokenKind::DayName(weekday)) => MonthTarget::OrdinalWeekday {
                        ordinal: OrdinalPosition::Last,
                        weekday,
                    },
                    _ => return Err(self.expected(expected::MONTH_LAST)),
                };
                self.advance();
                target
            }
            Some(&TokenKind::Ordinal(ordinal)) => {
                self.advance();
                let weekday = self.parse_day_name()?;
                MonthTarget::OrdinalWeekday { ordinal, weekday }
            }
            Some(TokenKind::OrdinalNumber(_)) => MonthTarget::Days(self.parse_ordinal_day_list()?),
            Some(TokenKind::Next | TokenKind::Previous | TokenKind::Nearest) => {
                self.parse_nearest_weekday_target()?
            }
            _ => return Err(self.expected(expected::MONTH_TARGET)),
        };

        self.expect(&TokenKind::At, expected::AT)?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::MonthRepeat {
            interval,
            target,
            times,
        })
    }

    fn parse_nearest_weekday_target(&mut self) -> Result<MonthTarget, ScheduleError> {
        let direction = if self.eat(&TokenKind::Next) {
            Some(NearestDirection::Next)
        } else if self.eat(&TokenKind::Previous) {
            Some(NearestDirection::Previous)
        } else {
            None
        };
        self.expect(&TokenKind::Nearest, expected::NEAREST)?;
        self.expect(&TokenKind::Weekday, expected::WEEKDAY)?;
        self.expect(&TokenKind::To, expected::TO)?;
        let (day, _) = self.parse_ordinal_day()?;
        Ok(MonthTarget::NearestWeekday { day, direction })
    }

    fn parse_ordinal_day_list(&mut self) -> Result<Vec<DayOfMonthSpec>, ScheduleError> {
        let mut specs = vec![self.parse_ordinal_day_spec()?];
        while self.eat(&TokenKind::Comma) {
            specs.push(self.parse_ordinal_day_spec()?);
        }
        Ok(specs)
    }

    fn parse_ordinal_day_spec(&mut self) -> Result<DayOfMonthSpec, ScheduleError> {
        let (start, start_token) = self.parse_ordinal_day()?;
        if !self.eat(&TokenKind::To) {
            return Ok(DayOfMonthSpec::Single(start));
        }
        let (end, end_token) = self.parse_ordinal_day()?;
        if start > end {
            return Err(self.error(
                format!(
                    "day range must not run backwards: {} to {}",
                    self.text(start_token),
                    self.text(end_token)
                ),
                start_token.start,
                end_token.end,
            ));
        }
        Ok(DayOfMonthSpec::Range(start, end))
    }

    fn parse_ordinal_day(&mut self) -> Result<(u8, &'a Token), ScheduleError> {
        let Some(&TokenKind::OrdinalNumber(n)) = self.peek_kind() else {
            return Err(self.expected(expected::DAY_OF_MONTH));
        };
        let token = self.advance();
        Ok((self.day_of_month(n, token)?, token))
    }

    fn parse_day_of(&mut self, month: MonthName) -> Result<u8, ScheduleError> {
        let (Some(&TokenKind::Number(n)) | Some(&TokenKind::OrdinalNumber(n))) = self.peek_kind()
        else {
            return Err(self.expected(expected::DAY_NUMBER));
        };
        let token = self.advance();
        let day = self.day_of_month(n, token)?;
        self.check_day_in_month(day, token, month)?;
        Ok(day)
    }

    fn day_of_month(&self, n: u32, token: &Token) -> Result<u8, ScheduleError> {
        match u8::try_from(n) {
            Ok(day) if (1..=31).contains(&day) => Ok(day),
            _ => Err(self.error(
                format!("day must be 1-31, got {}", self.text(token)),
                token.start,
                token.end,
            )),
        }
    }

    fn check_day_in_month(
        &self,
        day: u8,
        token: &Token,
        month: MonthName,
    ) -> Result<(), ScheduleError> {
        let max = match month {
            MonthName::February => 29,
            MonthName::April | MonthName::June | MonthName::September | MonthName::November => 30,
            _ => 31,
        };
        if day > max {
            return Err(self.error(
                format!(
                    "day must be 1-{max} for {}, got {}",
                    month.as_str(),
                    self.text(token)
                ),
                token.start,
                token.end,
            ));
        }
        Ok(())
    }

    fn parse_year_repeat(&mut self, interval: u32) -> Result<ScheduleExpr, ScheduleError> {
        self.expect(&TokenKind::On, expected::ON)?;

        let target = match self.peek_kind() {
            Some(TokenKind::The) => {
                self.advance();
                self.parse_year_target_after_the()?
            }
            Some(&TokenKind::MonthName(month)) => {
                self.advance();
                let day = self.parse_day_of(month)?;
                YearTarget::Date { month, day }
            }
            _ => return Err(self.expected(expected::YEAR_TARGET)),
        };

        self.expect(&TokenKind::At, expected::AT)?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::YearRepeat {
            interval,
            target,
            times,
        })
    }

    fn parse_year_target_after_the(&mut self) -> Result<YearTarget, ScheduleError> {
        match self.peek_kind() {
            Some(TokenKind::Last) => {
                self.advance();
                match self.peek_kind() {
                    Some(TokenKind::Weekday) => {
                        self.advance();
                        self.expect(&TokenKind::Of, expected::OF)?;
                        let month = self.parse_month_name()?;
                        Ok(YearTarget::LastWeekday { month })
                    }
                    Some(&TokenKind::DayName(weekday)) => {
                        self.advance();
                        self.expect(&TokenKind::Of, expected::OF)?;
                        let month = self.parse_month_name()?;
                        Ok(YearTarget::OrdinalWeekday {
                            ordinal: OrdinalPosition::Last,
                            weekday,
                            month,
                        })
                    }
                    _ => Err(self.expected(expected::YEAR_LAST)),
                }
            }
            Some(&TokenKind::Ordinal(ordinal)) => {
                self.advance();
                let weekday = self.parse_day_name()?;
                self.expect(&TokenKind::Of, expected::OF)?;
                let month = self.parse_month_name()?;
                Ok(YearTarget::OrdinalWeekday {
                    ordinal,
                    weekday,
                    month,
                })
            }
            Some(TokenKind::OrdinalNumber(_)) => {
                let (day, day_token) = self.parse_ordinal_day()?;
                self.expect(&TokenKind::Of, expected::OF)?;
                let month = self.parse_month_name()?;
                self.check_day_in_month(day, day_token, month)?;
                Ok(YearTarget::DayOfMonth { day, month })
            }
            _ => Err(self.expected(expected::YEAR_THE)),
        }
    }

    fn parse_month_name(&mut self) -> Result<MonthName, ScheduleError> {
        let Some(&TokenKind::MonthName(month)) = self.peek_kind() else {
            return Err(self.expected(expected::MONTH_NAME));
        };
        self.advance();
        Ok(month)
    }

    fn parse_month_list(&mut self) -> Result<Vec<MonthName>, ScheduleError> {
        let mut months = vec![self.parse_month_name()?];
        while self.eat(&TokenKind::Comma) {
            months.push(self.parse_month_name()?);
        }
        Ok(months)
    }

    fn parse_on(&mut self) -> Result<ScheduleExpr, ScheduleError> {
        let date = self.parse_date()?;
        self.expect(&TokenKind::At, expected::AT)?;
        let times = self.parse_time_list()?;
        Ok(ScheduleExpr::SingleDate { date, times })
    }

    fn parse_day_target(&mut self) -> Result<DayFilter, ScheduleError> {
        match self.peek_kind() {
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
            Some(TokenKind::DayName(_)) => Ok(DayFilter::Days(self.parse_day_list()?)),
            _ => Err(self.expected(expected::DAY_TARGET)),
        }
    }

    fn parse_day_name(&mut self) -> Result<Weekday, ScheduleError> {
        let Some(&TokenKind::DayName(weekday)) = self.peek_kind() else {
            return Err(self.expected(expected::DAY_NAME));
        };
        self.advance();
        Ok(weekday)
    }

    fn parse_day_list(&mut self) -> Result<Vec<Weekday>, ScheduleError> {
        let mut days = vec![self.parse_day_name()?];
        while self.eat(&TokenKind::Comma) {
            days.push(self.parse_day_name()?);
        }
        Ok(days)
    }

    fn parse_time_list(&mut self) -> Result<Vec<TimeOfDay>, ScheduleError> {
        let mut times = vec![self.parse_time()?];
        while self.eat(&TokenKind::Comma) {
            times.push(self.parse_time()?);
        }
        Ok(times)
    }

    fn parse_time(&mut self) -> Result<TimeOfDay, ScheduleError> {
        let Some(&TokenKind::Time(hour, minute)) = self.peek_kind() else {
            return Err(self.expected(expected::TIME));
        };
        self.advance();
        Ok(TimeOfDay { hour, minute })
    }
}

pub fn parse(input: &str) -> Result<Schedule, ScheduleError> {
    let tokens = Lexer::new(input).tokenize()?;
    if tokens.is_empty() {
        return Err(ScheduleError::parse(
            "empty expression",
            Span::new(0, 0),
            input,
            None,
        ));
    }

    let mut parser = Parser {
        tokens: &tokens,
        pos: 0,
        input,
        until_bytes: None,
    };
    let expr = parser.parse_expression()?;
    let schedule = parser.parse_clauses(expr)?;
    if parser.peek().is_some() {
        return Err(parser.leftover(&schedule));
    }
    // spec/README.md, "Parse errors": every other error wins over a named until without starting.
    parser.check_named_until(&schedule)?;
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
