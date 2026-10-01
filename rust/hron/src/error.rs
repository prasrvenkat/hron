use std::fmt;

/// The part of the input an error points at: `[start, end)` counted in code
/// points (`char`s), not bytes or UTF-16 units.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn new(start: usize, end: usize) -> Self {
        Self { start, end }
    }

    pub(crate) fn from_byte_range(input: &str, start: usize, end: usize) -> Self {
        let start_chars = input[..start].chars().count();
        Self::new(start_chars, start_chars + input[start..end].chars().count())
    }
}

#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum ScheduleError {
    Lex {
        message: String,
        span: Span,
        input: String,
    },

    Parse {
        message: String,
        span: Span,
        input: String,
        suggestion: Option<String>,
    },

    Eval {
        message: String,
    },

    Cron {
        message: String,
    },
}

impl fmt::Display for ScheduleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Lex { message, .. } => write!(f, "{message}"),
            Self::Parse { message, .. } => write!(f, "{message}"),
            Self::Eval { message } => write!(f, "{message}"),
            Self::Cron { message } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for ScheduleError {}

impl ScheduleError {
    pub fn lex(message: impl Into<String>, span: Span, input: impl Into<String>) -> Self {
        Self::Lex {
            message: message.into(),
            span,
            input: input.into(),
        }
    }

    pub fn parse(
        message: impl Into<String>,
        span: Span,
        input: impl Into<String>,
        suggestion: Option<String>,
    ) -> Self {
        Self::Parse {
            message: message.into(),
            span,
            input: input.into(),
            suggestion,
        }
    }

    pub fn eval(message: impl Into<String>) -> Self {
        Self::Eval {
            message: message.into(),
        }
    }

    pub fn cron(message: impl Into<String>) -> Self {
        Self::Cron {
            message: message.into(),
        }
    }

    /// The message, then for `lex` and `parse` errors the input and a line of
    /// carets under the span, and any suggestion as ` try: "..."`. No trailing newline.
    pub fn display_rich(&self) -> String {
        match self {
            Self::Lex {
                message,
                span,
                input,
            } => format_span_error(message, span, input, None),
            Self::Parse {
                message,
                span,
                input,
                suggestion,
            } => format_span_error(message, span, input, suggestion.as_deref()),
            Self::Eval { message } => format!("error: {message}"),
            Self::Cron { message } => format!("error: {message}"),
        }
    }
}

fn format_span_error(message: &str, span: &Span, input: &str, suggestion: Option<&str>) -> String {
    // A tab, CR or LF would move the input off the line the carets are aligned to.
    let shown: String = input
        .chars()
        .map(|c| {
            if matches!(c, '\t' | '\r' | '\n') {
                ' '
            } else {
                c
            }
        })
        .collect();
    let spaces = " ".repeat(span.start);
    let carets = "^".repeat(span.end.saturating_sub(span.start).max(1));
    let mut out = format!("error: {message}\n  {shown}\n  {spaces}{carets}");
    if let Some(suggestion) = suggestion {
        out.push_str(&format!(" try: \"{suggestion}\""));
    }
    out
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}..{}", self.start, self.end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_eval_and_cron_errors_render_their_message_alone() {
        assert_eq!(
            ScheduleError::eval("no zone").display_rich(),
            "error: no zone"
        );
        assert_eq!(
            ScheduleError::cron("bad cron").display_rich(),
            "error: bad cron"
        );
    }
}
