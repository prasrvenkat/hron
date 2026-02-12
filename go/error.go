package hron

import (
	"fmt"
	"strings"
)

// ErrorKind represents the type of error that occurred.
type ErrorKind string

const (
	ErrorKindLex   ErrorKind = "lex"
	ErrorKindParse ErrorKind = "parse"
	ErrorKindEval  ErrorKind = "eval"
	ErrorKindCron  ErrorKind = "cron"
)

// Span represents a range of character positions in the input.
type Span struct {
	Start int
	End   int
}

// HronError represents an error that occurred during parsing, evaluation, or conversion.
type HronError struct {
	Kind       ErrorKind
	Message    string
	Span       *Span
	Input      string
	Suggestion string
}

// Error implements the error interface.
func (e *HronError) Error() string {
	return e.Message
}

// LexError creates a new lexer error.
func LexError(message string, span Span, input string) *HronError {
	return &HronError{
		Kind:    ErrorKindLex,
		Message: message,
		Span:    &span,
		Input:   input,
	}
}

// ParseError creates a new parser error.
func ParseError(message string, span Span, input string, suggestion string) *HronError {
	return &HronError{
		Kind:       ErrorKindParse,
		Message:    message,
		Span:       &span,
		Input:      input,
		Suggestion: suggestion,
	}
}

// EvalError creates a new evaluation error.
func EvalError(message string) *HronError {
	return &HronError{
		Kind:    ErrorKindEval,
		Message: message,
	}
}

// CronError creates a new cron conversion error.
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

		// Add padding and underline
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
