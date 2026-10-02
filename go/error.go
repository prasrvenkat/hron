package hron

import (
	"strings"
	"unicode/utf8"
)

type ErrorKind string

const (
	ErrorKindLex   ErrorKind = "lex"
	ErrorKindParse ErrorKind = "parse"
	ErrorKindEval  ErrorKind = "eval"
	ErrorKindCron  ErrorKind = "cron"
)

// Span is the part of the input an error points at, [Start, End), counted in
// Unicode code points: each invalid UTF-8 byte counts as one.
type Span struct {
	Start int
	End   int
}

// RuneCountInString counts each invalid UTF-8 byte as one code point, as the spec does.
func codePointSpan(input string, start, end int) Span {
	startRunes := utf8.RuneCountInString(input[:start])
	return Span{startRunes, startRunes + utf8.RuneCountInString(input[start:end])}
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

// A tab, CR or LF would move the input off the line the carets are aligned to.
var lineBreaksAsSpaces = strings.NewReplacer("\t", " ", "\r", " ", "\n", " ")

// DisplayRich returns "error: " and the message, then for a lex or parse error
// the input and a line of carets under the span, and any suggestion as
// ` try: "..."`. Lines are joined by "\n", with no trailing newline.
func (e *HronError) DisplayRich() string {
	if (e.Kind != ErrorKindLex && e.Kind != ErrorKindParse) || e.Span == nil {
		return "error: " + e.Message
	}
	carets := max(e.Span.End-e.Span.Start, 1)
	out := "error: " + e.Message + "\n  " + lineBreaksAsSpaces.Replace(e.Input) + "\n  " +
		strings.Repeat(" ", e.Span.Start) + strings.Repeat("^", carets)
	if e.Suggestion != "" {
		out += ` try: "` + e.Suggestion + `"`
	}
	return out
}
