package hron

import (
	"errors"
	"testing"
)

func parseFailure(t *testing.T, input string) *HronError {
	t.Helper()
	_, err := ParseSchedule(input)
	var hronErr *HronError
	if !errors.As(err, &hronErr) {
		t.Fatalf("ParseSchedule(%q) error = %v, want a *HronError", input, err)
	}
	return hronErr
}

// JSON cannot carry invalid UTF-8 (spec/README.md, "Lex errors"), so these cases live here.
func TestErrorSpansCountCodePoints(t *testing.T) {
	tests := []struct {
		input   string
		kind    ErrorKind
		message string
		span    Span
	}{
		{"every day at 09:00 \xff", ErrorKindLex, "unexpected character U+FFFD", Span{19, 20}},
		// The three UTF-8 bytes of the lone surrogate U+D800 are each invalid, so each counts as
		// one code point, and the first is the one reported.
		{"every day at 09:00 \xed\xa0\x80", ErrorKindLex, "unexpected character U+FFFD", Span{19, 20}},
		{"every day at 09:00 in \xed\xa0\x80 foo", ErrorKindLex, "unknown keyword 'foo'", Span{26, 29}},
		{"every day at 09:00 in \xff\xfe foo", ErrorKindLex, "unknown keyword 'foo'", Span{25, 28}},
		{"every day at 09:00 in \xff", ErrorKindParse, "timezone must be UTC or an Area/Location name such as America/New_York, got \xff", Span{22, 23}},
		{"every day at 09:00 in é é", ErrorKindLex, "unexpected character U+00E9", Span{24, 25}},
		{"every day at 09:00 in \U0001f600 foo", ErrorKindLex, "unknown keyword 'foo'", Span{24, 27}},
		{"every day at 09:00 in Europe/İstanbul", ErrorKindParse, "timezone must be UTC or an Area/Location name such as America/New_York, got Europe/İstanbul", Span{22, 37}},
	}
	for _, tt := range tests {
		got := parseFailure(t, tt.input)
		if got.Kind != tt.kind || got.Message != tt.message || got.Span == nil || *got.Span != tt.span {
			t.Errorf("ParseSchedule(%q) = %s %q %v, want %s %q %v", tt.input, got.Kind, got.Message, got.Span, tt.kind, tt.message, tt.span)
		}
	}
}

func TestDisplayRichCountsCodePoints(t *testing.T) {
	got := parseFailure(t, "every day at 09:00 in \xff\U0001f600 foo").DisplayRich()
	want := "error: unknown keyword 'foo'\n  every day at 09:00 in \xff\U0001f600 foo\n                           ^^^"
	if got != want {
		t.Errorf("DisplayRich() = %q, want %q", got, want)
	}
}

func TestEvalAndCronErrorsRenderTheirMessageAlone(t *testing.T) {
	withSpan := &HronError{Kind: ErrorKindEval, Message: "no zone", Span: &Span{0, 1}, Input: "x"}
	for _, err := range []*HronError{EvalError("no zone"), CronError("bad cron"), withSpan} {
		if got, want := err.DisplayRich(), "error: "+err.Message; got != want {
			t.Errorf("DisplayRich() = %q, want %q", got, want)
		}
	}
}

func TestTokenSpansCountBytes(t *testing.T) {
	tokens, err := Tokenize("in é every")
	if err != nil {
		t.Fatal(err)
	}
	if tokens[1].Span != (Span{3, 5}) || tokens[2].Span != (Span{6, 11}) {
		t.Errorf("spans = %v, %v, want {3 5}, {6 11}", tokens[1].Span, tokens[2].Span)
	}
}

// spec/README.md, "Parse errors": only a range whose start is after its end fails.
func TestDayRangeMayStartAndEndOnOneDay(t *testing.T) {
	if _, err := ParseSchedule("every month on the 15th to 15th at 09:00"); err != nil {
		t.Errorf("an equal day range failed: %v", err)
	}
}
