package hron

import (
	"fmt"
	"strings"
)

type ErrorKind string

const (
	ErrorKindLex   ErrorKind = "lex"
	ErrorKindParse ErrorKind = "parse"
	ErrorKindEval  ErrorKind = "eval"
	ErrorKindCron  ErrorKind = "cron"
)

// Span is a byte range in the input: Start inclusive, End exclusive.
type Span struct {
	Start int
	End   int
}

type HronError struct {
	Kind       ErrorKind
	Message    string
	Span       *Span
	Input      string
	Suggestion string
}

func (e *HronError) Error() string {
	return e.Message
}

func LexError(message string, span Span, input string) *HronError {
	return &HronError{
		Kind:    ErrorKindLex,
		Message: message,
		Span:    &span,
		Input:   input,
	}
}

func ParseError(message string, span Span, input string, suggestion string) *HronError {
	return &HronError{
		Kind:       ErrorKindParse,
		Message:    message,
		Span:       &span,
		Input:      input,
		Suggestion: suggestion,
	}
}

func EvalError(message string) *HronError {
	return &HronError{
		Kind:    ErrorKindEval,
		Message: message,
	}
}

func CronError(message string) *HronError {
	return &HronError{
		Kind:    ErrorKindCron,
		Message: message,
	}
}

// DisplayRich formats a rich error message with underline and optional suggestion.
func (e *HronError) DisplayRich() string {
	if (e.Kind == ErrorKindLex || e.Kind == ErrorKindParse) && e.Span != nil && e.Input != "" {
		var sb strings.Builder
		sb.WriteString(fmt.Sprintf("error: %s\n", e.Message))
		sb.WriteString(fmt.Sprintf("  %s\n", e.Input))

		padding := strings.Repeat(" ", e.Span.Start+2)
		underlineLen := e.Span.End - e.Span.Start
		if underlineLen < 1 {
			underlineLen = 1
		}
		underline := strings.Repeat("^", underlineLen)
		sb.WriteString(padding)
		sb.WriteString(underline)

		if e.Suggestion != "" {
			sb.WriteString(fmt.Sprintf(" try: \"%s\"", e.Suggestion))
		}

		return sb.String()
	}

	return fmt.Sprintf("error: %s", e.Message)
}
