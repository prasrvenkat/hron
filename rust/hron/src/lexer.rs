use crate::error::{ScheduleError, Span};

/// Token produced by the lexer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenKind {
    // Keywords
    Every,
    On,
    At,
    From,
    To,
    In,
    Of,
    The,
    Last,
    Except,
    Until,
    Starting,
    During,
    Year,

    // Day keywords
    Day,
    Weekday,
    Weekend,
    Weeks,
    Month,

    // Day names
    DayName(String), // lowercase full name: "monday", "tuesday", ...

    // Month names
    MonthName(String), // lowercase short: "jan", "feb", ...

    // Ordinals
    Ordinal(String), // "first", "second", "third", "fourth", "fifth"

    // Interval units
    IntervalUnit(String), // "min", "mins", "minute", "minutes", "hour", "hours", "hr", "hrs"

    // Literals
    Number(u32),
    OrdinalNumber(u32), // 1st, 2nd, 3rd, 15th — the number part
    Time(u8, u8),       // HH:MM
    IsoDate(String),    // 2026-03-15

    // Punctuation
    Comma,

    // Timezone (IANA string)
    Timezone(String),
}

pub struct Lexer<'a> {
    input: &'a str,
    bytes: &'a [u8],
    pos: usize,
    /// Set after we emit an `In` token so we know to parse a timezone next.
    after_in: bool,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        Self {
            input,
            bytes: input.as_bytes(),
            pos: 0,
            after_in: false,
        }
    }

    pub fn tokenize(&mut self) -> Result<Vec<Token>, ScheduleError> {
        let mut tokens = Vec::new();
        loop {
            self.skip_whitespace();
            if self.pos >= self.bytes.len() {
                break;
            }

            // After `in` keyword, consume the rest as a timezone string
            if self.after_in {
                self.after_in = false;
                let tok = self.lex_timezone()?;
                tokens.push(tok);
                continue;
            }

            let start = self.pos;
            let ch = self.bytes[self.pos];

            if ch == b',' {
                self.pos += 1;
                tokens.push(Token {
                    kind: TokenKind::Comma,
                    span: Span::new(start, self.pos),
                });
                continue;
            }

            // Try time literal: HH:MM (but not ISO date YYYY-MM-DD)
            if ch.is_ascii_digit() {
                let tok = self.lex_number_or_time_or_date()?;
                tokens.push(tok);
                continue;
            }

            // Word
            if ch.is_ascii_alphabetic() {
                let tok = self.lex_word()?;
                tokens.push(tok);
                continue;
            }

            return Err(ScheduleError::lex(
                format!("unexpected character '{}'", ch as char),
                Span::new(start, start + 1),
                self.input,
            ));
        }
        Ok(tokens)
    }

    fn skip_whitespace(&mut self) {
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn lex_timezone(&mut self) -> Result<Token, ScheduleError> {
        self.skip_whitespace();
        let start = self.pos;
        // Consume everything remaining as the timezone
        while self.pos < self.bytes.len() && !self.bytes[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
        // IANA timezones are single tokens like "America/Vancouver" or "UTC", no spaces.
        let tz = &self.input[start..self.pos];
        if tz.is_empty() {
            return Err(ScheduleError::lex(
                "expected timezone after 'in'",
                Span::new(start, start + 1),
                self.input,
            ));
        }
        Ok(Token {
            kind: TokenKind::Timezone(tz.to_string()),
            span: Span::new(start, self.pos),
        })
    }

    fn lex_number_or_time_or_date(&mut self) -> Result<Token, ScheduleError> {
        let start = self.pos;
        // Read digits
        let num_start = self.pos;
        while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
            self.pos += 1;
        }
        let digits = &self.input[num_start..self.pos];

        // Check for ISO date: YYYY-MM-DD
        if digits.len() == 4
            && self.pos < self.bytes.len()
            && self.bytes[self.pos] == b'-'
            && self.pos + 3 <= self.bytes.len()
        {
            // Peek ahead to see if this is YYYY-MM-DD
            let remaining = &self.input[self.pos..];
            if remaining.len() >= 6 {
                let maybe_date = &self.input[start..];
                if maybe_date.len() >= 10
                    && maybe_date.as_bytes()[4] == b'-'
                    && maybe_date.as_bytes()[5].is_ascii_digit()
                    && maybe_date.as_bytes()[6].is_ascii_digit()
                    && maybe_date.as_bytes()[7] == b'-'
                    && maybe_date.as_bytes()[8].is_ascii_digit()
                    && maybe_date.as_bytes()[9].is_ascii_digit()
                {
                    self.pos = start + 10;
                    return Ok(Token {
                        kind: TokenKind::IsoDate(self.input[start..self.pos].to_string()),
                        span: Span::new(start, self.pos),
                    });
                }
            }
        }

        // Check for time: HH:MM
        if (digits.len() == 1 || digits.len() == 2)
            && self.pos < self.bytes.len()
            && self.bytes[self.pos] == b':'
        {
            self.pos += 1; // skip ':'
            let min_start = self.pos;
            while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_digit() {
                self.pos += 1;
            }
            let min_digits = &self.input[min_start..self.pos];
            if min_digits.len() == 2 {
                let hour: u8 = digits.parse().map_err(|_| {
                    ScheduleError::lex("invalid hour", Span::new(start, self.pos), self.input)
                })?;
                let minute: u8 = min_digits.parse().map_err(|_| {
                    ScheduleError::lex("invalid minute", Span::new(start, self.pos), self.input)
                })?;
                if hour > 23 || minute > 59 {
                    return Err(ScheduleError::lex(
                        "invalid time",
                        Span::new(start, self.pos),
                        self.input,
                    ));
                }
                return Ok(Token {
                    kind: TokenKind::Time(hour, minute),
                    span: Span::new(start, self.pos),
                });
            }
        }

        let num: u32 = digits.parse().map_err(|_| {
            ScheduleError::lex("invalid number", Span::new(start, self.pos), self.input)
        })?;

        // Check for ordinal suffix: st, nd, rd, th
        if self.pos + 1 < self.bytes.len() {
            let suffix = &self.input[self.pos..self.pos + 2].to_lowercase();
            if matches!(suffix.as_str(), "st" | "nd" | "rd" | "th") {
                self.pos += 2;
                return Ok(Token {
                    kind: TokenKind::OrdinalNumber(num),
                    span: Span::new(start, self.pos),
                });
            }
        }

        Ok(Token {
            kind: TokenKind::Number(num),
            span: Span::new(start, self.pos),
        })
    }

    fn lex_word(&mut self) -> Result<Token, ScheduleError> {
        let start = self.pos;
        while self.pos < self.bytes.len()
            && (self.bytes[self.pos].is_ascii_alphanumeric() || self.bytes[self.pos] == b'_')
        {
            self.pos += 1;
        }
        let word = self.input[start..self.pos].to_lowercase();

        let kind = match word.as_str() {
            "every" => TokenKind::Every,
            "on" => TokenKind::On,
            "at" => TokenKind::At,
            "from" => TokenKind::From,
            "to" => TokenKind::To,
            "in" => {
                self.after_in = true;
                TokenKind::In
            }
            "of" => TokenKind::Of,
            "the" => TokenKind::The,
            "last" => TokenKind::Last,
            "except" => TokenKind::Except,
            "until" => TokenKind::Until,
            "starting" => TokenKind::Starting,
            "during" => TokenKind::During,
            "year" => TokenKind::Year,

            "day" => TokenKind::Day,
            "weekday" | "weekdays" => TokenKind::Weekday,
            "weekend" | "weekends" => TokenKind::Weekend,
            "weeks" | "week" => TokenKind::Weeks,
            "month" => TokenKind::Month,

            "monday" | "mon" => TokenKind::DayName("monday".into()),
            "tuesday" | "tue" => TokenKind::DayName("tuesday".into()),
            "wednesday" | "wed" => TokenKind::DayName("wednesday".into()),
            "thursday" | "thu" => TokenKind::DayName("thursday".into()),
            "friday" | "fri" => TokenKind::DayName("friday".into()),
            "saturday" | "sat" => TokenKind::DayName("saturday".into()),
            "sunday" | "sun" => TokenKind::DayName("sunday".into()),

            "january" | "jan" => TokenKind::MonthName("jan".into()),
            "february" | "feb" => TokenKind::MonthName("feb".into()),
            "march" | "mar" => TokenKind::MonthName("mar".into()),
            "april" | "apr" => TokenKind::MonthName("apr".into()),
            "may" => TokenKind::MonthName("may".into()),
            "june" | "jun" => TokenKind::MonthName("jun".into()),
            "july" | "jul" => TokenKind::MonthName("jul".into()),
            "august" | "aug" => TokenKind::MonthName("aug".into()),
            "september" | "sep" => TokenKind::MonthName("sep".into()),
            "october" | "oct" => TokenKind::MonthName("oct".into()),
            "november" | "nov" => TokenKind::MonthName("nov".into()),
            "december" | "dec" => TokenKind::MonthName("dec".into()),

            "first" => TokenKind::Ordinal("first".into()),
            "second" => TokenKind::Ordinal("second".into()),
            "third" => TokenKind::Ordinal("third".into()),
            "fourth" => TokenKind::Ordinal("fourth".into()),
            "fifth" => TokenKind::Ordinal("fifth".into()),

            "min" | "mins" | "minute" | "minutes" => TokenKind::IntervalUnit("min".into()),
            "hour" | "hours" | "hr" | "hrs" => TokenKind::IntervalUnit("hours".into()),

            _ => {
                return Err(ScheduleError::lex(
                    format!("unknown keyword '{word}'"),
                    Span::new(start, self.pos),
                    self.input,
                ));
            }
        };

        Ok(Token {
            kind,
            span: Span::new(start, self.pos),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_day_repeat() {
        let mut lexer = Lexer::new("every day at 09:00");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens.len(), 4);
        assert_eq!(tokens[0].kind, TokenKind::Every);
        assert_eq!(tokens[1].kind, TokenKind::Day);
        assert_eq!(tokens[2].kind, TokenKind::At);
        assert_eq!(tokens[3].kind, TokenKind::Time(9, 0));
    }

    #[test]
    fn test_iso_date() {
        let mut lexer = Lexer::new("on 2026-03-15 at 14:30");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[1].kind, TokenKind::IsoDate("2026-03-15".into()));
        assert_eq!(tokens[3].kind, TokenKind::Time(14, 30));
    }

    #[test]
    fn test_ordinal_number() {
        let mut lexer = Lexer::new("every month on the 1st at 09:00");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[3].kind, TokenKind::The);
        assert_eq!(tokens[4].kind, TokenKind::OrdinalNumber(1));
    }

    #[test]
    fn test_timezone() {
        let mut lexer = Lexer::new("every day at 09:00 in America/Vancouver");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(
            tokens.last().unwrap().kind,
            TokenKind::Timezone("America/Vancouver".into())
        );
    }

    #[test]
    fn test_interval() {
        let mut lexer = Lexer::new("every 30 min from 09:00 to 17:00");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[1].kind, TokenKind::Number(30));
        assert_eq!(tokens[2].kind, TokenKind::IntervalUnit("min".into()));
    }

    #[test]
    fn test_except_token() {
        let mut lexer = Lexer::new("every weekday at 09:00 except dec 25");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[4].kind, TokenKind::Except);
        assert_eq!(tokens[5].kind, TokenKind::MonthName("dec".into()));
    }

    #[test]
    fn test_until_token() {
        let mut lexer = Lexer::new("every day at 09:00 until 2026-12-31");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[4].kind, TokenKind::Until);
        assert_eq!(tokens[5].kind, TokenKind::IsoDate("2026-12-31".into()));
    }

    #[test]
    fn test_starting_token() {
        let mut lexer = Lexer::new("every 2 weeks on monday at 09:00 starting 2026-01-05");
        let tokens = lexer.tokenize().unwrap();
        assert!(tokens.iter().any(|t| t.kind == TokenKind::Starting));
    }

    #[test]
    fn test_year_token() {
        let mut lexer = Lexer::new("every year on dec 25 at 00:00");
        let tokens = lexer.tokenize().unwrap();
        assert_eq!(tokens[1].kind, TokenKind::Year);
    }
}
