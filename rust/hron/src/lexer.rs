use crate::ast::{
    parse_month_name, parse_weekday, IntervalUnit, MonthName, OrdinalPosition, Weekday,
};
use crate::error::{ScheduleError, Span};

const MAX_NUMBER: u32 = i32::MAX as u32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub kind: TokenKind,
    /// Byte offsets into the input. Errors convert them to code points.
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenKind {
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
    Nearest,
    Next,
    Previous,

    Day,
    Weekday,
    Weekend,
    Week,
    Month,
    Year,

    DayName(Weekday),
    MonthName(MonthName),
    Ordinal(OrdinalPosition),
    IntervalUnit(IntervalUnit),

    Number(u32),
    OrdinalNumber(u32),
    Time(u8, u8),
    IsoDate,
    Comma,
    Timezone,
}

pub struct Lexer<'a> {
    input: &'a str,
    pos: usize,
}

impl<'a> Lexer<'a> {
    pub fn new(input: &'a str) -> Self {
        Self { input, pos: 0 }
    }

    pub fn tokenize(mut self) -> Result<Vec<Token>, ScheduleError> {
        let mut tokens: Vec<Token> = Vec::new();
        loop {
            self.advance_while(is_whitespace);
            let Some(c) = self.input[self.pos..].chars().next() else {
                break;
            };
            let start = self.pos;
            let kind = if tokens.last().is_some_and(|t| t.kind == TokenKind::In) {
                self.advance_while(|b| !is_whitespace(b));
                TokenKind::Timezone
            } else if c == ',' {
                self.pos += 1;
                TokenKind::Comma
            } else if c.is_ascii_alphabetic() {
                self.word(start)?
            } else if c.is_ascii_digit() {
                self.digits(start)?
            } else {
                return Err(self.unexpected_character(c, start));
            };
            tokens.push(Token {
                kind,
                start,
                end: self.pos,
            });
        }
        Ok(tokens)
    }

    fn advance_while(&mut self, matches: impl Fn(u8) -> bool) {
        let bytes = self.input.as_bytes();
        while self.pos < bytes.len() && matches(bytes[self.pos]) {
            self.pos += 1;
        }
    }

    fn rest(&self) -> &[u8] {
        &self.input.as_bytes()[self.pos..]
    }

    fn error(&self, message: String, start: usize) -> ScheduleError {
        let span = Span::from_byte_range(self.input, start, self.pos);
        ScheduleError::lex(message, span, self.input)
    }

    fn word(&mut self, start: usize) -> Result<TokenKind, ScheduleError> {
        self.advance_while(|b| b.is_ascii_alphanumeric() || b == b'_');
        let text = &self.input[start..self.pos];
        keyword(&text.to_ascii_lowercase())
            .ok_or_else(|| self.error(format!("unknown keyword '{text}'"), start))
    }

    fn digits(&mut self, start: usize) -> Result<TokenKind, ScheduleError> {
        self.advance_while(|b| b.is_ascii_digit());
        let digits = &self.input[start..self.pos];
        if digits.len() == 4 && is_iso_date_tail(self.rest()) {
            self.pos += "-MM-DD".len();
            return Ok(TokenKind::IsoDate);
        }
        if self.rest().starts_with(b":") {
            return self.time(start);
        }
        let value = number_value(digits)
            .ok_or_else(|| self.error("number must be at most 2147483647".into(), start))?;
        let suffix = self.rest().get(..2).map(<[u8]>::to_ascii_lowercase);
        if matches!(suffix.as_deref(), Some(b"st" | b"nd" | b"rd" | b"th")) {
            self.pos += 2;
            return Ok(TokenKind::OrdinalNumber(value));
        }
        Ok(TokenKind::Number(value))
    }

    fn time(&mut self, start: usize) -> Result<TokenKind, ScheduleError> {
        let colon = self.pos;
        self.pos += 1;
        self.advance_while(|b| b.is_ascii_digit());
        let (hour, minute) = (&self.input[start..colon], &self.input[colon + 1..self.pos]);
        let text = &self.input[start..self.pos];
        if !(1..=2).contains(&hour.len()) || minute.len() != 2 {
            return Err(self.error(format!("time must be H:MM or HH:MM, got {text}"), start));
        }
        let (hour, minute) = (two_digit_value(hour), two_digit_value(minute));
        if hour > 23 || minute > 59 {
            return Err(self.error(format!("time must be 00:00-23:59, got {text}"), start));
        }
        Ok(TokenKind::Time(hour, minute))
    }

    fn unexpected_character(&self, c: char, start: usize) -> ScheduleError {
        // `'` is excluded because `'''` would not read as a quoted character.
        let shown = if ('!'..='~').contains(&c) && c != '\'' {
            format!("'{c}'")
        } else {
            format!("U+{:04X}", u32::from(c))
        };
        let span = Span::from_byte_range(self.input, start, start + c.len_utf8());
        ScheduleError::lex(format!("unexpected character {shown}"), span, self.input)
    }
}

/// Only these four separate tokens; any other whitespace is an unexpected character.
fn is_whitespace(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\r' | b'\n')
}

fn is_iso_date_tail(rest: &[u8]) -> bool {
    matches!(rest, [b'-', m1, m2, b'-', d1, d2, ..] if [m1, m2, d1, d2].iter().all(|b| b.is_ascii_digit()))
}

/// Checked at every digit, so a run of any length cannot overflow.
fn number_value(digits: &str) -> Option<u32> {
    digits
        .bytes()
        .try_fold(0u32, |n, d| {
            n.checked_mul(10)?.checked_add(u32::from(d - b'0'))
        })
        .filter(|&n| n <= MAX_NUMBER)
}

fn two_digit_value(digits: &str) -> u8 {
    digits.bytes().fold(0, |n, d| n * 10 + (d - b'0'))
}

fn keyword(word: &str) -> Option<TokenKind> {
    let kind = match word {
        "every" => TokenKind::Every,
        "on" => TokenKind::On,
        "at" => TokenKind::At,
        "from" => TokenKind::From,
        "to" => TokenKind::To,
        "in" => TokenKind::In,
        "of" => TokenKind::Of,
        "the" => TokenKind::The,
        "last" => TokenKind::Last,
        "except" => TokenKind::Except,
        "until" => TokenKind::Until,
        "starting" => TokenKind::Starting,
        "during" => TokenKind::During,
        "nearest" => TokenKind::Nearest,
        "next" => TokenKind::Next,
        "previous" => TokenKind::Previous,

        "day" | "days" => TokenKind::Day,
        "weekday" | "weekdays" => TokenKind::Weekday,
        "weekend" | "weekends" => TokenKind::Weekend,
        "week" | "weeks" => TokenKind::Week,
        "month" | "months" => TokenKind::Month,
        "year" | "years" => TokenKind::Year,

        "first" => TokenKind::Ordinal(OrdinalPosition::First),
        "second" => TokenKind::Ordinal(OrdinalPosition::Second),
        "third" => TokenKind::Ordinal(OrdinalPosition::Third),
        "fourth" => TokenKind::Ordinal(OrdinalPosition::Fourth),
        "fifth" => TokenKind::Ordinal(OrdinalPosition::Fifth),

        "min" | "mins" | "minute" | "minutes" => TokenKind::IntervalUnit(IntervalUnit::Minutes),
        "hour" | "hours" | "hr" | "hrs" => TokenKind::IntervalUnit(IntervalUnit::Hours),

        _ => {
            return parse_weekday(word)
                .map(TokenKind::DayName)
                .or_else(|| parse_month_name(word).map(TokenKind::MonthName))
        }
    };
    Some(kind)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(input: &str) -> Vec<TokenKind> {
        Lexer::new(input)
            .tokenize()
            .unwrap()
            .into_iter()
            .map(|t| t.kind)
            .collect()
    }

    #[test]
    fn test_simple_day_repeat() {
        assert_eq!(
            kinds("every day at 09:00"),
            [
                TokenKind::Every,
                TokenKind::Day,
                TokenKind::At,
                TokenKind::Time(9, 0)
            ]
        );
    }

    #[test]
    fn test_iso_date() {
        let kinds = kinds("on 2026-03-15 at 14:30");
        assert_eq!(kinds[1], TokenKind::IsoDate);
        assert_eq!(kinds[3], TokenKind::Time(14, 30));
    }

    #[test]
    fn test_ordinal_number() {
        assert_eq!(
            kinds("every month on the 1st at 09:00")[4],
            TokenKind::OrdinalNumber(1)
        );
    }

    #[test]
    fn test_timezone() {
        let tokens = Lexer::new("every day at 09:00 in America/Vancouver")
            .tokenize()
            .unwrap();
        let tz = tokens.last().unwrap();
        assert_eq!(tz.kind, TokenKind::Timezone);
        assert_eq!(
            &"every day at 09:00 in America/Vancouver"[tz.start..tz.end],
            "America/Vancouver"
        );
    }

    #[test]
    fn test_interval() {
        let kinds = kinds("every 30 min from 09:00 to 17:00");
        assert_eq!(kinds[1], TokenKind::Number(30));
        assert_eq!(kinds[2], TokenKind::IntervalUnit(IntervalUnit::Minutes));
    }

    #[test]
    fn test_every_spelling_in_any_ascii_case() {
        let spellings = "every on at from to in of the last except until starting during nearest \
            next previous day days weekday weekdays weekend weekends week weeks month months \
            year years min mins minute minutes hour hours hr hrs monday mon tuesday tue \
            wednesday wed thursday thu friday fri saturday sat sunday sun january jan february \
            feb march mar april apr may june jun july jul august aug september sep october oct \
            november nov december dec first second third fourth fifth";
        for word in spellings.split_whitespace() {
            let alternating: String = word
                .chars()
                .enumerate()
                .map(|(i, c)| {
                    if i % 2 == 0 {
                        c.to_ascii_uppercase()
                    } else {
                        c
                    }
                })
                .collect();
            for written in [word.to_string(), word.to_ascii_uppercase(), alternating] {
                let tokens = Lexer::new(&written).tokenize();
                assert!(
                    tokens.is_ok_and(|t| t.len() == 1),
                    "'{written}' is not one word"
                );
            }
        }
    }

    #[test]
    fn test_word_runs_through_underscore_and_digits() {
        let error = Lexer::new("every_day2 at 09:00").tokenize().unwrap_err();
        assert_eq!(error.to_string(), "unknown keyword 'every_day2'");
        assert!(matches!(error, ScheduleError::Lex { span, .. } if span == Span::new(0, 10)));
    }

    #[test]
    fn test_token_offsets_are_bytes() {
        let tokens = Lexer::new("in é every").tokenize().unwrap();
        assert_eq!((tokens[1].start, tokens[1].end), (3, 5));
        assert_eq!((tokens[2].start, tokens[2].end), (6, 11));
    }
}
