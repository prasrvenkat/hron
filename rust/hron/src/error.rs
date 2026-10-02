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

/// What failed: spec/README.md, "Error Types".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ErrorKind {
    Lex,
    Parse,
    Eval,
    Cron,
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
        f.write_str(self.message())
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

    pub fn kind(&self) -> ErrorKind {
        match self {
            Self::Lex { .. } => ErrorKind::Lex,
            Self::Parse { .. } => ErrorKind::Parse,
            Self::Eval { .. } => ErrorKind::Eval,
            Self::Cron { .. } => ErrorKind::Cron,
        }
    }

    /// The same text as `to_string()`.
    pub fn message(&self) -> &str {
        match self {
            Self::Lex { message, .. }
            | Self::Parse { message, .. }
            | Self::Eval { message }
            | Self::Cron { message } => message,
        }
    }

    /// `Some` for `lex` and `parse` errors only.
    pub fn span(&self) -> Option<Span> {
        match self {
            Self::Lex { span, .. } | Self::Parse { span, .. } => Some(*span),
            Self::Eval { .. } | Self::Cron { .. } => None,
        }
    }

    /// The expression as given; `Some` for `lex` and `parse` errors only.
    pub fn input(&self) -> Option<&str> {
        match self {
            Self::Lex { input, .. } | Self::Parse { input, .. } => Some(input),
            Self::Eval { .. } | Self::Cron { .. } => None,
        }
    }

    /// Text to put in place of the span; only a `parse` error may have one.
    pub fn suggestion(&self) -> Option<&str> {
        match self {
            Self::Parse { suggestion, .. } => suggestion.as_deref(),
            Self::Lex { .. } | Self::Eval { .. } | Self::Cron { .. } => None,
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
