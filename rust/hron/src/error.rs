use std::fmt;

/// Byte range within the input string.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
}

impl Span {
    pub fn new(start: usize, end: usize) -> Self {
        Self { start, end }
    }
}

/// All errors produced by hron.
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

    /// Format a rich error with underline and optional suggestion.
    pub fn display_rich(&self) -> String {
        match self {
            Self::Lex {
                message,
                span,
                input,
            } => format_span_error("error", message, span, input, None),
            Self::Parse {
                message,
                span,
                input,
                suggestion,
            } => format_span_error("error", message, span, input, suggestion.as_deref()),
            Self::Eval { message } => format!("error: {message}"),
            Self::Cron { message } => format!("error: {message}"),
        }
    }
}

fn format_span_error(
    prefix: &str,
    message: &str,
    span: &Span,
    input: &str,
    suggestion: Option<&str>,
) -> String {
    let mut out = format!("{prefix}: {message}\n");
    out.push_str(&format!("  {input}\n"));
    let padding = " ".repeat(span.start + 2);
    let underline = "^".repeat((span.end - span.start).max(1));
    out.push_str(&padding);
    out.push_str(&underline);
    if let Some(sug) = suggestion {
        out.push_str(&format!(" try: \"{sug}\""));
    }
    out
}

impl fmt::Display for Span {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}..{}", self.start, self.end)
    }
}
