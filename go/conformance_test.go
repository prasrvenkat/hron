package hron

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

type TestSpec struct {
	Now         string                     `json:"now"`
	Parse       map[string]json.RawMessage `json:"parse"`
	ParseErrors json.RawMessage            `json:"parse_errors"`
	Eval        map[string]json.RawMessage `json:"eval"`
	Cron        map[string]json.RawMessage `json:"cron"`
	Invariants  json.RawMessage            `json:"invariants"`
}

type InvariantSettings struct {
	Count int               `json:"count"`
	Rules map[string]string `json:"rules"`
}

type InvariantTest struct {
	Name       string `json:"name"`
	Expression string `json:"expression"`
	Now        string `json:"now"`
}

type ParseTest struct {
	Name      string `json:"name"`
	Input     string `json:"input"`
	Canonical string `json:"canonical"`
}

type ParseErrorTest struct {
	Name        string                     `json:"name"`
	Input       string                     `json:"input"`
	Description string                     `json:"description"`
	Error       map[string]json.RawMessage `json:"error"`
	Display     *string                    `json:"display"`
}

type expectedParseError struct {
	Kind       string  `json:"kind"`
	Message    string  `json:"message"`
	Span       [2]int  `json:"span"`
	Suggestion *string `json:"suggestion"`
}

type EvalTest struct {
	Name        string          `json:"name"`
	Expression  string          `json:"expression"`
	Description string          `json:"description,omitempty"`
	Now         string          `json:"now,omitempty"`
	Next        json.RawMessage `json:"next,omitempty"`
	NextDate    json.RawMessage `json:"next_date,omitempty"`
	NextN       *[]string       `json:"next_n,omitempty"`
	NextNCount  *int            `json:"next_n_count,omitempty"`
	NextNLength *int            `json:"next_n_length,omitempty"`
}

type OccurrencesTest struct {
	Name        string    `json:"name"`
	Expression  string    `json:"expression"`
	Description string    `json:"description,omitempty"`
	From        string    `json:"from"`
	Take        int       `json:"take"`
	Expected    *[]string `json:"expected"`
}

type BetweenTest struct {
	Name          string    `json:"name"`
	Expression    string    `json:"expression"`
	Description   string    `json:"description,omitempty"`
	From          string    `json:"from"`
	To            string    `json:"to"`
	Expected      *[]string `json:"expected,omitempty"`
	ExpectedCount *int      `json:"expected_count,omitempty"`
}

type PreviousFromTest struct {
	Name        string          `json:"name"`
	Expression  string          `json:"expression"`
	Description string          `json:"description,omitempty"`
	Now         string          `json:"now"`
	Expected    json.RawMessage `json:"expected"`
}

type ToCronTest struct {
	Name string `json:"name"`
	Hron string `json:"hron"`
	Cron string `json:"cron"`
}

type ToCronErrorTest struct {
	Name  string `json:"name"`
	Hron  string `json:"hron"`
	Error string `json:"error"`
}

type FromCronTest struct {
	Name string `json:"name"`
	Cron string `json:"cron"`
	Hron string `json:"hron"`
}

type FromCronErrorTest struct {
	Name  string `json:"name"`
	Cron  string `json:"cron"`
	Error string `json:"error"`
}

type RoundtripTest struct {
	Name string `json:"name"`
	Hron string `json:"hron"`
}

func readSpec(t *testing.T) []byte {
	data, err := os.ReadFile("../spec/tests.json")
	if err != nil {
		t.Fatalf("failed to read spec: %v", err)
	}
	return data
}

func loadSpec(t *testing.T) *TestSpec {
	data := readSpec(t)

	var spec TestSpec
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatalf("failed to parse spec: %v", err)
	}
	return &spec
}

// A case field outside fields fails the test, because this runner would not
// check it; name and description are labels.
func decodeCases[T any](t *testing.T, section json.RawMessage, fields ...string) []T {
	t.Helper()
	var group struct {
		Tests []json.RawMessage `json:"tests"`
	}
	if err := json.Unmarshal(section, &group); err != nil {
		t.Fatalf("failed to parse section: %v", err)
	}
	cases := make([]T, len(group.Tests))
	for i, raw := range group.Tests {
		var caseFields map[string]json.RawMessage
		if err := json.Unmarshal(raw, &caseFields); err != nil {
			t.Fatalf("failed to parse case %d: %v", i, err)
		}
		for field := range caseFields {
			if field != "name" && field != "description" && !slices.Contains(fields, field) {
				t.Errorf("case %s: field %q is not checked by this runner", caseFields["name"], field)
			}
		}
		if err := json.Unmarshal(raw, &cases[i]); err != nil {
			t.Fatalf("failed to parse case %s: %v", caseFields["name"], err)
		}
	}
	return cases
}

func parseZonedDateTime(s string) (time.Time, error) {
	re := regexp.MustCompile(`^(.+?)\[([^\]]+)\]$`)
	matches := re.FindStringSubmatch(s)
	if matches == nil {
		return time.Parse(time.RFC3339, s)
	}

	isoStr := matches[1]
	tzName := matches[2]

	loc, err := time.LoadLocation(tzName)
	if err != nil {
		return time.Parse(time.RFC3339, isoStr)
	}

	t, err := time.Parse(time.RFC3339, isoStr)
	if err != nil {
		return time.Time{}, err
	}

	return t.In(loc), nil
}

// TestSpecSections fails on any section this runner does not check, so that a
// new section cannot pass unchecked (spec/README.md, "Writing a runner").
// Every eval section other than the four TestEval skips is a nextFrom section.
func TestSpecSections(t *testing.T) {
	var top map[string]json.RawMessage
	if err := json.Unmarshal(readSpec(t), &top); err != nil {
		t.Fatalf("failed to parse spec: %v", err)
	}
	checkKnownKeys(t, "top-level", top, "$schema", "version", "description", "now", "_eval_assertion_types",
		"_behavioral_notes", "parse", "parse_errors", "eval", "cron", "invariants")

	checkKnownKeys(t, "cron", loadSpec(t).Cron, "description", "to_cron", "to_cron_errors", "from_cron", "from_cron_errors", "roundtrip")
}

func checkKnownKeys(t *testing.T, where string, sections map[string]json.RawMessage, known ...string) {
	for name := range sections {
		if !slices.Contains(known, name) {
			t.Errorf("unknown %s section %q: this runner does not check it", where, name)
		}
	}
}

func TestParse(t *testing.T) {
	spec := loadSpec(t)

	for section, raw := range spec.Parse {
		if section == "description" {
			continue
		}

		t.Run(section, func(t *testing.T) {
			for _, tc := range decodeCases[ParseTest](t, raw, "input", "canonical") {
				t.Run(tc.Name, func(t *testing.T) {
					if tc.Canonical == "" {
						t.Fatalf("case has no canonical to assert")
					}
					s, err := ParseSchedule(tc.Input)
					if err != nil {
						t.Fatalf("failed to parse %q: %v", tc.Input, err)
					}

					got := s.String()
					if got != tc.Canonical {
						t.Errorf("parse(%q).String() = %q, want %q", tc.Input, got, tc.Canonical)
					}
					assertRebuilds(t, tc.Input, s)
					if !s.Equal(MustParse(got)) {
						t.Errorf("parse(%q) does not equal the parse of its String() %q", tc.Input, got)
					}

					s2, err := ParseSchedule(tc.Canonical)
					if err != nil {
						t.Fatalf("failed to parse canonical %q: %v", tc.Canonical, err)
					}
					got2 := s2.String()
					if got2 != tc.Canonical {
						t.Errorf("roundtrip: parse(%q).String() = %q, want %q", tc.Canonical, got2, tc.Canonical)
					}
				})
			}
		})
	}
}

func TestParseErrors(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[ParseErrorTest](t, spec.ParseErrors, "input", "error", "display") {
		t.Run(tc.Name, func(t *testing.T) {
			want := decodeExpectedParseError(t, tc.Error)
			if Validate(tc.Input) {
				t.Errorf("Validate(%q) = true, want false", tc.Input)
			}
			_, err := ParseSchedule(tc.Input)
			var got *HronError
			if !errors.As(err, &got) {
				t.Fatalf("ParseSchedule(%q) error = %v, want a *HronError", tc.Input, err)
			}
			if string(got.Kind) != want.Kind {
				t.Errorf("kind for %q = %q, want %q", tc.Input, got.Kind, want.Kind)
			}
			if got.Message != want.Message {
				t.Errorf("message for %q = %q, want %q", tc.Input, got.Message, want.Message)
			}
			if got.Span == nil || [2]int{got.Span.Start, got.Span.End} != want.Span {
				t.Errorf("span for %q = %v, want %v", tc.Input, got.Span, want.Span)
			}
			wantSuggestion := ""
			if want.Suggestion != nil {
				wantSuggestion = *want.Suggestion
			}
			if got.Suggestion != wantSuggestion {
				t.Errorf("suggestion for %q = %q, want %q", tc.Input, got.Suggestion, wantSuggestion)
			}
			if tc.Display != nil && got.DisplayRich() != *tc.Display {
				t.Errorf("DisplayRich for %q =\n%s\nwant\n%s", tc.Input, got.DisplayRich(), *tc.Display)
			}
		})
	}
}

// Fails on a field inside "error" that this runner does not check (spec/README.md, "Writing a runner").
func decodeExpectedParseError(t *testing.T, fields map[string]json.RawMessage) expectedParseError {
	t.Helper()
	for _, required := range []string{"kind", "message", "span"} {
		if _, ok := fields[required]; !ok {
			t.Fatalf("error has no %q field", required)
		}
	}
	for field := range fields {
		if !slices.Contains([]string{"kind", "message", "span", "suggestion"}, field) {
			t.Fatalf("error field %q is not checked by this runner", field)
		}
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		t.Fatal(err)
	}
	var want expectedParseError
	if err := json.Unmarshal(raw, &want); err != nil {
		t.Fatalf("failed to decode error %s: %v", raw, err)
	}
	return want
}

func TestEval(t *testing.T) {
	spec := loadSpec(t)

	defaultNow, err := parseZonedDateTime(spec.Now)
	if err != nil {
		t.Fatalf("failed to parse default now: %v", err)
	}

	for section, raw := range spec.Eval {
		if section == "description" || section == "occurrences" || section == "between" || section == "matches" || section == "previous_from" {
			continue
		}

		t.Run(section, func(t *testing.T) {
			cases := decodeCases[EvalTest](t, raw, "expression", "now", "next", "next_date", "next_n", "next_n_count", "next_n_length")
			for _, tc := range cases {
				t.Run(tc.Name, func(t *testing.T) {
					if tc.Next == nil && tc.NextDate == nil && tc.NextN == nil && tc.NextNLength == nil {
						t.Fatalf("case has no assertion field this runner understands (next, next_date, next_n, next_n_length)")
					}
					s, err := ParseSchedule(tc.Expression)
					if err != nil {
						t.Fatalf("failed to parse %q: %v", tc.Expression, err)
					}

					now := defaultNow
					if tc.Now != "" {
						now, err = parseZonedDateTime(tc.Now)
						if err != nil {
							t.Fatalf("failed to parse now %q: %v", tc.Now, err)
						}
					}

					if tc.Next != nil {
						checkTimestamp(t, "NextFrom()", s.NextFrom(now), expectedTimestamp(t, tc.Next))
					}

					if tc.NextDate != nil {
						var wantDate *string
						if err := json.Unmarshal(tc.NextDate, &wantDate); err != nil {
							t.Fatalf("failed to read next_date %s: %v", tc.NextDate, err)
						}
						result := s.NextFrom(now)
						switch {
						case wantDate == nil && result != nil:
							t.Errorf("NextFrom() = %v, want nil", *result)
						case wantDate != nil && result == nil:
							t.Errorf("NextFrom() = nil, want date %s", *wantDate)
						case wantDate != nil && result.Format("2006-01-02") != *wantDate:
							t.Errorf("NextFrom() date = %s, want %s", result.Format("2006-01-02"), *wantDate)
						}
					}

					if tc.NextN != nil {
						n := len(*tc.NextN)
						if tc.NextNCount != nil {
							n = *tc.NextNCount
						}
						checkTimestamps(t, "NextNFrom()", s.NextNFrom(now, n), *tc.NextN)
					}

					if tc.NextNLength != nil {
						if tc.NextNCount == nil {
							t.Fatalf("next_n_length has no next_n_count")
						}
						results := s.NextNFrom(now, *tc.NextNCount)
						if len(results) != *tc.NextNLength {
							t.Errorf("NextNFrom() returned %d results, want %d", len(results), *tc.NextNLength)
						}
					}
				})
			}
		})
	}
}

func TestOccurrences(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[OccurrencesTest](t, spec.Eval["occurrences"], "expression", "from", "take", "expected") {
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Expected == nil {
				t.Fatalf("case has no expected list")
			}
			expectedList := *tc.Expected
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			from, err := parseZonedDateTime(tc.From)
			if err != nil {
				t.Fatalf("failed to parse from %q: %v", tc.From, err)
			}

			var results []time.Time
			count := 0
			for dt := range s.Occurrences(from) {
				if count >= tc.Take {
					break
				}
				results = append(results, dt)
				count++
			}

			checkTimestamps(t, "Occurrences()", results, expectedList)
		})
	}
}

func TestBetween(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[BetweenTest](t, spec.Eval["between"], "expression", "from", "to", "expected", "expected_count") {
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Expected == nil && tc.ExpectedCount == nil {
				t.Fatalf("case has neither expected nor expected_count")
			}
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			from, err := parseZonedDateTime(tc.From)
			if err != nil {
				t.Fatalf("failed to parse from %q: %v", tc.From, err)
			}

			to, err := parseZonedDateTime(tc.To)
			if err != nil {
				t.Fatalf("failed to parse to %q: %v", tc.To, err)
			}

			var results []time.Time
			for dt := range s.Between(from, to) {
				results = append(results, dt)
			}

			if tc.ExpectedCount != nil {
				if len(results) != *tc.ExpectedCount {
					t.Errorf("Between() returned %d results, want %d", len(results), *tc.ExpectedCount)
				}
			}
			if tc.Expected != nil {
				checkTimestamps(t, "Between()", results, *tc.Expected)
			}
		})
	}
}

func TestPreviousFrom(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[PreviousFromTest](t, spec.Eval["previous_from"], "expression", "now", "expected") {
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Expected == nil {
				t.Fatalf("case has no expected field")
			}
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			now, err := parseZonedDateTime(tc.Now)
			if err != nil {
				t.Fatalf("failed to parse now %q: %v", tc.Now, err)
			}

			checkTimestamp(t, "PreviousFrom()", s.PreviousFrom(now), expectedTimestamp(t, tc.Expected))
		})
	}
}

func TestToCron(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[ToCronTest](t, spec.Cron["to_cron"], "hron", "cron") {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Hron)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Hron, err)
			}

			got, err := s.ToCron()
			if err != nil {
				t.Fatalf("ToCron() failed: %v", err)
			}

			if got != tc.Cron {
				t.Errorf("ToCron() = %q, want %q", got, tc.Cron)
			}
		})
	}
}

func TestToCronErrors(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[ToCronErrorTest](t, spec.Cron["to_cron_errors"], "hron", "error") {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Hron)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Hron, err)
			}

			_, err = s.ToCron()
			assertCronError(t, err, tc.Error)
		})
	}
}

func TestFromCron(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[FromCronTest](t, spec.Cron["from_cron"], "cron", "hron") {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := FromCronExpr(tc.Cron)
			if err != nil {
				t.Fatalf("FromCron(%q) failed: %v", tc.Cron, err)
			}

			got := s.String()
			if got != tc.Hron {
				t.Errorf("FromCron(%q).String() = %q, want %q", tc.Cron, got, tc.Hron)
			}
			if !s.Equal(MustParse(got)) {
				t.Errorf("FromCron(%q) does not equal the parse of its String() %q", tc.Cron, got)
			}
		})
	}
}

func TestFromCronErrors(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[FromCronErrorTest](t, spec.Cron["from_cron_errors"], "cron", "error") {
		t.Run(tc.Name, func(t *testing.T) {
			_, err := FromCronExpr(tc.Cron)
			assertCronError(t, err, tc.Error)
		})
	}
}

func assertCronError(t *testing.T, err error, message string) {
	t.Helper()
	var hronErr *HronError
	if !errors.As(err, &hronErr) {
		t.Fatalf("expected a cron error %q, got %v", message, err)
	}
	if hronErr.Kind != ErrorKindCron || hronErr.Message != message {
		t.Errorf("got %s error %q, want cron error %q", hronErr.Kind, hronErr.Message, message)
	}
}

func TestCronRoundtrip(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[RoundtripTest](t, spec.Cron["roundtrip"], "hron") {
		t.Run(tc.Name, func(t *testing.T) {
			s1, err := ParseSchedule(tc.Hron)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Hron, err)
			}

			cron, err := s1.ToCron()
			if err != nil {
				t.Fatalf("ToCron() failed: %v", err)
			}

			s2, err := FromCronExpr(cron)
			if err != nil {
				t.Fatalf("FromCron(%q) failed: %v", cron, err)
			}

			cron2, err := s2.ToCron()
			if err != nil {
				t.Fatalf("ToCron() failed on roundtrip: %v", err)
			}

			if cron != cron2 {
				t.Errorf("roundtrip failed: %q -> %q -> %q -> %q", tc.Hron, cron, s2.String(), cron2)
			}
		})
	}
}

type MatchesTest struct {
	Name       string `json:"name"`
	Expression string `json:"expression"`
	Datetime   string `json:"datetime"`
	Expected   *bool  `json:"expected"`
}

func TestMatches(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range decodeCases[MatchesTest](t, spec.Eval["matches"], "expression", "datetime", "expected") {
		t.Run(tc.Name, func(t *testing.T) {
			if tc.Expected == nil {
				t.Fatalf("case has no expected field")
			}
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			dt, err := parseZonedDateTime(tc.Datetime)
			if err != nil {
				t.Fatalf("failed to parse datetime %q: %v", tc.Datetime, err)
			}

			got := s.Matches(dt)
			if got != *tc.Expected {
				t.Errorf("Matches(%q, %v) = %v, want %v", tc.Expression, dt, got, *tc.Expected)
			}
		})
	}
}

func TestTimezone(t *testing.T) {
	s1, err := ParseSchedule("every day at 09:00")
	if err != nil {
		t.Fatal(err)
	}
	if s1.Timezone() != "" {
		t.Errorf("Timezone() = %q, want empty", s1.Timezone())
	}

	s2, err := ParseSchedule("every day at 09:00 in America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	if s2.Timezone() != "America/New_York" {
		t.Errorf("Timezone() = %q, want %q", s2.Timezone(), "America/New_York")
	}
}

func TestValidate(t *testing.T) {
	if !Validate("every day at 09:00") {
		t.Error("expected valid expression to return true")
	}
	if Validate("not a schedule") {
		t.Error("expected invalid expression to return false")
	}
}

func TestExactTimeBoundary(t *testing.T) {
	s, err := ParseSchedule("every day at 12:00 in UTC")
	if err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	next := s.NextFrom(now)
	if next == nil {
		t.Fatal("expected non-nil result")
	}

	expected := time.Date(2026, 2, 7, 12, 0, 0, 0, time.UTC)
	if !next.Equal(expected) {
		t.Errorf("NextFrom() = %v, want %v", next, expected)
	}
}

func TestIntervalAlignment(t *testing.T) {
	s, err := ParseSchedule("every 3 days at 09:00 in UTC")
	if err != nil {
		t.Fatal(err)
	}

	// Feb 6, 2026 is day 20490 from the epoch, a multiple of 3, so the next
	// aligned day after its 09:00 is Feb 9.
	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	next := s.NextFrom(now)
	if next == nil {
		t.Fatal("expected non-nil result")
	}

	expected := time.Date(2026, 2, 9, 9, 0, 0, 0, time.UTC)
	if !next.Equal(expected) {
		t.Errorf("NextFrom() = %v, want %v", next, expected)
	}
}

func expectedTimestamp(t *testing.T, raw json.RawMessage) *string {
	if strings.TrimSpace(string(raw)) == "null" {
		return nil
	}
	var str string
	if err := json.Unmarshal(raw, &str); err != nil {
		t.Fatalf("failed to read expected timestamp %s: %v", raw, err)
	}
	return &str
}

// Go's -07:00 layout drops an offset's seconds, and -07:00:00 writes
// Africa/Accra's -00:00:52 as +00:00:-52.
func formatZoned(t time.Time) string {
	_, offset := t.Zone()
	sign := '+'
	if offset < 0 {
		sign, offset = '-', -offset
	}
	zone := fmt.Sprintf("%c%02d:%02d", sign, offset/3600, offset/60%60)
	if offset%60 != 0 {
		zone += fmt.Sprintf(":%02d", offset%60)
	}
	return t.Format("2006-01-02T15:04:05") + zone + "[" + t.Location().String() + "]"
}

func checkTimestamp(t *testing.T, call string, got *time.Time, want *string) {
	switch {
	case want == nil && got != nil:
		t.Errorf("%s = %s, want nil", call, formatZoned(*got))
	case want != nil && got == nil:
		t.Errorf("%s = nil, want %s", call, *want)
	case want != nil && formatZoned(*got) != *want:
		t.Errorf("%s = %s, want %s", call, formatZoned(*got), *want)
	}
}

func checkTimestamps(t *testing.T, call string, got []time.Time, want []string) {
	formatted := make([]string, len(got))
	for i, g := range got {
		formatted[i] = formatZoned(g)
	}
	if !slices.Equal(formatted, want) {
		t.Errorf("%s = %v, want %v", call, formatted, want)
	}
}

var invariantRules = map[string]func(t *testing.T, s *Schedule, now time.Time, count int){
	"next_matches":       checkNextMatches,
	"next_after_now":     checkNextAfterNow,
	"next_n_chain":       checkNextNChain,
	"occurrences_prefix": checkOccurrencesPrefix,
	"between_window":     checkBetweenWindow,
	"prev_inverse":       checkPrevInverse,
	"prev_before_now":    checkPrevBeforeNow,
	"display_roundtrip":  checkDisplayRoundtrip,
}

func TestInvariants(t *testing.T) {
	spec := loadSpec(t)
	var settings InvariantSettings
	if err := json.Unmarshal(spec.Invariants, &settings); err != nil {
		t.Fatalf("failed to parse invariants section: %v", err)
	}
	count := settings.Count
	ruleNames := slices.Sorted(maps.Keys(settings.Rules))
	if len(ruleNames) == 0 {
		t.Fatalf("invariants section lists no rules")
	}

	for _, tc := range decodeCases[InvariantTest](t, spec.Invariants, "expression", "now") {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}
			now, err := parseZonedDateTime(tc.Now)
			if err != nil {
				t.Fatalf("failed to parse now %q: %v", tc.Now, err)
			}
			for _, name := range ruleNames {
				t.Run(name, func(t *testing.T) {
					check, ok := invariantRules[name]
					if !ok {
						t.Fatalf("rule %q is not implemented by this runner", name)
					}
					check(t, s, now, count)
				})
			}
		})
	}
}

func checkNextMatches(t *testing.T, s *Schedule, now time.Time, _ int) {
	next := s.NextFrom(now)
	if next != nil && !s.Matches(*next) {
		t.Errorf("%q: NextFrom(%v) = %v, but Matches(%v) is false", s, now, *next, *next)
	}
}

func checkNextAfterNow(t *testing.T, s *Schedule, now time.Time, _ int) {
	if next := s.NextFrom(now); next != nil && !next.After(now) {
		t.Errorf("%q: NextFrom(%v) = %v is not after now", s, now, *next)
	}
}

func checkNextNChain(t *testing.T, s *Schedule, now time.Time, count int) {
	list := s.NextNFrom(now, count)
	next := s.NextFrom(now)
	if next == nil {
		if len(list) != 0 {
			t.Errorf("%q: NextFrom(%v) = nil, but NextNFrom = %v", s, now, list)
		}
		return
	}
	if len(list) == 0 || !list[0].Equal(*next) {
		t.Errorf("%q: NextNFrom(%v) = %v does not start with NextFrom = %v", s, now, list, *next)
		return
	}
	for i := 1; i < len(list); i++ {
		if !list[i].After(list[i-1]) {
			t.Errorf("%q: NextNFrom(%v) is not strictly increasing at %d: %v", s, now, i, list)
		}
		following := s.NextFrom(list[i-1])
		if following == nil || !following.Equal(list[i]) {
			t.Errorf("%q: NextFrom(%v) = %v, but NextNFrom has %v", s, list[i-1], following, list[i])
		}
	}
}

func checkOccurrencesPrefix(t *testing.T, s *Schedule, now time.Time, count int) {
	var taken []time.Time
	for dt := range s.Occurrences(now) {
		if len(taken) == count {
			break
		}
		taken = append(taken, dt)
	}
	if want := s.NextNFrom(now, count); !sameInstants(taken, want) {
		t.Errorf("%q: first %d of Occurrences(%v) = %v, NextNFrom = %v", s, count, now, taken, want)
	}
}

func checkBetweenWindow(t *testing.T, s *Schedule, now time.Time, count int) {
	want := s.NextNFrom(now, count)
	if len(want) == 0 {
		return
	}
	last := want[len(want)-1]
	var got []time.Time
	for dt := range s.Between(now, last) {
		got = append(got, dt)
	}
	if !sameInstants(got, want) {
		t.Errorf("%q: Between(%v, %v) = %v, NextNFrom = %v", s, now, last, got, want)
	}
}

func checkPrevInverse(t *testing.T, s *Schedule, now time.Time, count int) {
	list := s.NextNFrom(now, count)
	for i := 1; i < len(list); i++ {
		prev := s.PreviousFrom(list[i])
		if prev == nil || !prev.Equal(list[i-1]) {
			t.Errorf("%q: PreviousFrom(%v) = %v, want %v", s, list[i], prev, list[i-1])
		}
	}
}

func checkPrevBeforeNow(t *testing.T, s *Schedule, now time.Time, _ int) {
	prev := s.PreviousFrom(now)
	if prev == nil {
		return
	}
	if !prev.Before(now) {
		t.Errorf("%q: PreviousFrom(%v) = %v is not before now", s, now, *prev)
	}
	if !s.Matches(*prev) {
		t.Errorf("%q: PreviousFrom(%v) = %v, but Matches(%v) is false", s, now, *prev, *prev)
	}
	if next := s.NextFrom(*prev); next != nil && next.Before(now) {
		t.Errorf("%q: PreviousFrom(%v) = %v, but NextFrom(%v) = %v is earlier than now", s, now, *prev, *prev, *next)
	}
}

func checkDisplayRoundtrip(t *testing.T, s *Schedule, _ time.Time, _ int) {
	display := s.String()
	reparsed, err := ParseSchedule(display)
	if err != nil {
		t.Fatalf("%q: failed to re-parse display %q: %v", s, display, err)
	}
	if got := reparsed.String(); got != display {
		t.Errorf("%q: re-parsed display is %q", display, got)
	}
}

func sameInstants(a, b []time.Time) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !a[i].Equal(b[i]) {
			return false
		}
	}
	return true
}

type buildCase struct {
	Name      string          `json:"name"`
	Parts     json.RawMessage `json:"parts"`
	Error     json.RawMessage `json:"error"`
	Canonical *string         `json:"canonical"`
}

type buildError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

type buildPartsJSON struct {
	Expression json.RawMessage   `json:"expression"`
	Except     []json.RawMessage `json:"except"`
	Until      json.RawMessage   `json:"until"`
	Starting   *string           `json:"starting"`
	During     []string          `json:"during"`
	Timezone   *string           `json:"timezone"`
}

type buildRepeatJSON struct {
	Interval  json.Number     `json:"interval"`
	Unit      string          `json:"unit"`
	From      string          `json:"from"`
	To        string          `json:"to"`
	DayFilter json.RawMessage `json:"day_filter"`
	Days      json.RawMessage `json:"days"`
	Target    json.RawMessage `json:"target"`
	Date      json.RawMessage `json:"date"`
	Times     []string        `json:"times"`
}

type buildNamedJSON struct {
	Month   string  `json:"month"`
	Day     int     `json:"day"`
	Ordinal string  `json:"ordinal"`
	Weekday string  `json:"weekday"`
	Dir     *string `json:"direction"`
}

var (
	buildWeekdays = []string{"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}
	buildMonths   = []string{"january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"}
	buildOrdinals = []string{"first", "second", "third", "fourth", "fifth", "last"}
)

func TestBuild(t *testing.T) {
	raw, err := os.ReadFile("../spec/build.json")
	if err != nil {
		t.Fatalf("failed to read build.json: %v", err)
	}
	var groups map[string]json.RawMessage
	if err := json.Unmarshal(raw, &groups); err != nil {
		t.Fatalf("failed to parse build.json: %v", err)
	}
	checkKnownKeys(t, "build.json", groups, "description", "rules", "order", "canonical")
	for _, group := range []string{"rules", "order", "canonical"} {
		t.Run(group, func(t *testing.T) {
			for _, tc := range decodeCases[buildCase](t, groups[group], "parts", "error", "canonical") {
				t.Run(tc.Name, func(t *testing.T) { runBuild(t, tc) })
			}
		})
	}
}

// spec/README.md, "Writing a runner": in Go the empty timezone means none, so
// a case with "timezone": "" builds as the parts without one; and a value
// Go's int cannot hold is checked by failing to write it there.
func runBuild(t *testing.T, tc buildCase) {
	if (tc.Error == nil) == (tc.Canonical == nil) {
		t.Fatalf("case needs exactly one of error and canonical")
	}
	parts, emptyTimezone, fits := buildPartsOf(t, tc.Parts)
	if !fits {
		if tc.Error == nil {
			t.Fatalf("int cannot hold a value of a case that builds")
		}
		return
	}
	s, err := NewSchedule(parts)
	switch {
	case emptyTimezone:
		if err != nil {
			t.Fatalf("NewSchedule with the empty timezone failed: %v", err)
		}
		if s.Timezone() != "" {
			t.Errorf("Timezone() = %q, want none", s.Timezone())
		}
		assertParsesBack(t, s)
	case tc.Error != nil:
		var want buildError
		strictDecode(t, tc.Error, &want)
		if want.Kind != "eval" {
			t.Fatalf("case expects a %q error", want.Kind)
		}
		var got *HronError
		if !errors.As(err, &got) {
			t.Fatalf("NewSchedule = %v, %v, want an eval error", s, err)
		}
		if got.Kind != ErrorKindEval || got.Message != want.Message {
			t.Errorf("got %s error %q, want eval error %q", got.Kind, got.Message, want.Message)
		}
		if got.Span != nil || got.Input != "" || got.Suggestion != "" {
			t.Errorf("error has span %v, input %q, suggestion %q, want none", got.Span, got.Input, got.Suggestion)
		}
		if got.DisplayRich() != "error: "+want.Message {
			t.Errorf("DisplayRich() = %q", got.DisplayRich())
		}
	default:
		if err != nil {
			t.Fatalf("NewSchedule failed: %v", err)
		}
		if s.String() != *tc.Canonical {
			t.Errorf("String() = %q, want %q", s.String(), *tc.Canonical)
		}
		assertParsesBack(t, s)
	}
}

// spec/README.md, "Schedules built in code": building from a parsed
// schedule's parts gives an equal schedule, and parse already writes the parts
// as building keeps them.
func assertRebuilds(t *testing.T, input string, s *Schedule) {
	t.Helper()
	rebuilt, err := NewSchedule(s.Data())
	if err != nil {
		t.Fatalf("NewSchedule(parse(%q).Data()) failed: %v", input, err)
	}
	if !reflect.DeepEqual(rebuilt.data, s.data) || rebuilt.String() != s.String() {
		t.Errorf("NewSchedule(parse(%q).Data()) = %q %+v, want %q %+v", input, rebuilt, *rebuilt.data, s, *s.data)
	}
	raw, err := parse(input)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(raw, s.data) {
		t.Errorf("parse(%q) = %+v, NewSchedule keeps %+v", input, *raw, *s.data)
	}
}

func assertParsesBack(t *testing.T, s *Schedule) {
	t.Helper()
	parsed, err := ParseSchedule(s.String())
	if err != nil {
		t.Fatalf("%q does not parse: %v", s, err)
	}
	if !parsed.Equal(s) {
		t.Errorf("parse(%q) = %+v, built %+v", s, *parsed.data, *s.data)
	}
}

func strictDecode(t *testing.T, raw json.RawMessage, v any) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(v); err != nil {
		t.Fatalf("cannot read %s: %v", raw, err)
	}
}

// Kinds share a struct to decode into, so each checks its own keys.
func allowKeys(t *testing.T, raw json.RawMessage, allowed ...string) {
	t.Helper()
	var object map[string]json.RawMessage
	strictDecode(t, raw, &object)
	for key := range object {
		if !slices.Contains(allowed, key) {
			t.Fatalf("field %q is not checked by this runner in %s", key, raw)
		}
	}
}

func onlyKey(t *testing.T, raw json.RawMessage) (string, json.RawMessage) {
	t.Helper()
	var object map[string]json.RawMessage
	strictDecode(t, raw, &object)
	if len(object) != 1 {
		t.Fatalf("%s should have exactly one key", raw)
	}
	for key, value := range object {
		return key, value
	}
	panic("unreachable")
}

func buildPartsOf(t *testing.T, raw json.RawMessage) (parts *ScheduleData, emptyTimezone, fits bool) {
	var in buildPartsJSON
	strictDecode(t, raw, &in)
	expr, fits := buildExpr(t, in.Expression)
	if !fits {
		return nil, false, false
	}
	parts = &ScheduleData{Expression: expr}
	for _, exception := range in.Except {
		date := buildDate(t, exception)
		except := NewISOException(date.Date)
		if date.Kind == DateSpecKindNamed {
			except = NewNamedException(date.Month, date.Day)
		}
		parts.Except = append(parts.Except, except)
	}
	if in.Until != nil {
		date := buildDate(t, in.Until)
		until := NewISOUntil(date.Date)
		if date.Kind == DateSpecKindNamed {
			until = NewNamedUntil(date.Month, date.Day)
		}
		parts.Until = &until
	}
	if in.Starting != nil {
		parts.Starting = *in.Starting
	}
	for _, month := range in.During {
		parts.During = append(parts.During, MonthName(buildName(t, buildMonths, month)))
	}
	if in.Timezone != nil {
		parts.Timezone = *in.Timezone
	}
	return parts, in.Timezone != nil && *in.Timezone == "", true
}

func buildExpr(t *testing.T, raw json.RawMessage) (ScheduleExpr, bool) {
	kind, body := onlyKey(t, raw)
	var in buildRepeatJSON
	strictDecode(t, body, &in)
	times := make([]TimeOfDay, len(in.Times))
	for i, text := range in.Times {
		times[i] = buildTime(t, text)
	}
	allowKeys(t, body, map[string][]string{
		"interval_repeat": {"interval", "unit", "from", "to", "day_filter"},
		"day_repeat":      {"interval", "days", "times"},
		"week_repeat":     {"interval", "days", "times"},
		"month_repeat":    {"interval", "target", "times"},
		"single_date":     {"date", "times"},
		"year_repeat":     {"interval", "target", "times"},
	}[kind]...)
	interval := 0
	if in.Interval != "" {
		var err error
		interval, err = strconv.Atoi(in.Interval.String())
		if errors.Is(err, strconv.ErrRange) {
			return ScheduleExpr{}, false
		}
		if err != nil {
			t.Fatalf("interval %s is not an integer", in.Interval)
		}
	}
	switch kind {
	case "interval_repeat":
		var filter *DayFilter
		if in.DayFilter != nil {
			f := buildDayFilter(t, in.DayFilter)
			filter = &f
		}
		unit := IntervalUnit(buildName(t, []string{"minutes", "hours"}, in.Unit) - 1)
		return NewIntervalRepeat(interval, unit, buildTime(t, in.From), buildTime(t, in.To), filter), true
	case "day_repeat":
		return NewDayRepeat(interval, buildDayFilter(t, in.Days), times), true
	case "week_repeat":
		return NewWeekRepeat(interval, buildWeekdayList(t, in.Days), times), true
	case "month_repeat":
		return NewMonthRepeat(interval, buildMonthTarget(t, in.Target), times), true
	case "single_date":
		return NewSingleDateExpr(buildDate(t, in.Date), times), true
	case "year_repeat":
		return NewYearRepeat(interval, buildYearTarget(t, in.Target), times), true
	}
	t.Fatalf("unknown expression %q", kind)
	return ScheduleExpr{}, false
}

func buildName(t *testing.T, names []string, name string) int {
	t.Helper()
	i := slices.Index(names, name)
	if i < 0 {
		t.Fatalf("%q is not one of %v", name, names)
	}
	return i + 1
}

func buildTime(t *testing.T, text string) TimeOfDay {
	hour, minute, found := strings.Cut(text, ":")
	h, errH := strconv.Atoi(hour)
	m, errM := strconv.Atoi(minute)
	if !found || errH != nil || errM != nil {
		t.Fatalf("cannot read the time %q", text)
	}
	return TimeOfDay{Hour: h, Minute: m}
}

func buildWeekdayList(t *testing.T, raw json.RawMessage) []Weekday {
	var names []string
	strictDecode(t, raw, &names)
	days := make([]Weekday, len(names))
	for i, name := range names {
		days[i] = Weekday(buildName(t, buildWeekdays, name))
	}
	return days
}

func buildDayFilter(t *testing.T, raw json.RawMessage) DayFilter {
	var name string
	if json.Unmarshal(raw, &name) == nil {
		return [...]DayFilter{NewDayFilterEvery(), NewDayFilterWeekday(), NewDayFilterWeekend()}[buildName(t, []string{"every", "weekday", "weekend"}, name)-1]
	}
	key, days := onlyKey(t, raw)
	if key != "days" {
		t.Fatalf("unknown day filter %q", key)
	}
	return NewDayFilterDays(buildWeekdayList(t, days))
}

func buildMonthTarget(t *testing.T, raw json.RawMessage) MonthTarget {
	var name string
	if json.Unmarshal(raw, &name) == nil {
		return [...]MonthTarget{NewLastDayTarget(), NewLastWeekdayTarget()}[buildName(t, []string{"last_day", "last_weekday"}, name)-1]
	}
	key, body := onlyKey(t, raw)
	if key == "days" {
		var items []json.RawMessage
		strictDecode(t, body, &items)
		specs := make([]DayOfMonthSpec, len(items))
		for i, item := range items {
			specs[i] = buildDayOfMonthSpec(t, item)
		}
		return NewDaysTarget(specs)
	}
	var in buildNamedJSON
	strictDecode(t, body, &in)
	allowKeys(t, body, map[string][]string{"nearest_weekday": {"day", "direction"}, "ordinal_weekday": {"ordinal", "weekday"}}[key]...)
	switch key {
	case "nearest_weekday":
		direction := NearestNone
		if in.Dir != nil {
			direction = NearestDirection(buildName(t, []string{"next", "previous"}, *in.Dir))
		}
		return NewNearestWeekdayTarget(in.Day, direction)
	case "ordinal_weekday":
		return NewOrdinalWeekdayTarget(OrdinalPosition(buildName(t, buildOrdinals, in.Ordinal)), Weekday(buildName(t, buildWeekdays, in.Weekday)))
	}
	t.Fatalf("unknown month target %q", key)
	return MonthTarget{}
}

func buildDayOfMonthSpec(t *testing.T, raw json.RawMessage) DayOfMonthSpec {
	key, body := onlyKey(t, raw)
	switch key {
	case "single":
		var day int
		strictDecode(t, body, &day)
		return NewSingleDay(day)
	case "range":
		var bounds [2]int
		strictDecode(t, body, &bounds)
		return NewDayRange(bounds[0], bounds[1])
	}
	t.Fatalf("unknown day spec %q", key)
	return DayOfMonthSpec{}
}

func buildYearTarget(t *testing.T, raw json.RawMessage) YearTarget {
	key, body := onlyKey(t, raw)
	var in buildNamedJSON
	strictDecode(t, body, &in)
	allowKeys(t, body, map[string][]string{
		"date":            {"month", "day"},
		"ordinal_weekday": {"ordinal", "weekday", "month"},
		"day_of_month":    {"day", "month"},
		"last_weekday":    {"month"},
	}[key]...)
	month := MonthName(buildName(t, buildMonths, in.Month))
	switch key {
	case "date":
		return NewYearDateTarget(month, in.Day)
	case "ordinal_weekday":
		return NewYearOrdinalWeekdayTarget(OrdinalPosition(buildName(t, buildOrdinals, in.Ordinal)), Weekday(buildName(t, buildWeekdays, in.Weekday)), month)
	case "day_of_month":
		return NewYearDayOfMonthTarget(in.Day, month)
	case "last_weekday":
		return NewYearLastWeekdayTarget(month)
	}
	t.Fatalf("unknown year target %q", key)
	return YearTarget{}
}

func buildDate(t *testing.T, raw json.RawMessage) DateSpec {
	key, body := onlyKey(t, raw)
	switch key {
	case "named":
		var in buildNamedJSON
		strictDecode(t, body, &in)
		allowKeys(t, body, "month", "day")
		return NewNamedDate(MonthName(buildName(t, buildMonths, in.Month)), in.Day)
	case "iso":
		var date string
		strictDecode(t, body, &date)
		return NewISODate(date)
	}
	t.Fatalf("unknown date %q", key)
	return DateSpec{}
}
