package hron

import (
	"encoding/json"
	"errors"
	"maps"
	"os"
	"regexp"
	"slices"
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
	Name          string `json:"name"`
	Input         string `json:"input"`
	Description   string `json:"description"`
	ErrorContains string `json:"error_contains"`
}

type EvalTest struct {
	Name        string          `json:"name"`
	Expression  string          `json:"expression"`
	Description string          `json:"description,omitempty"`
	Now         string          `json:"now,omitempty"`
	Next        json.RawMessage `json:"next,omitempty"`
	NextDate    json.RawMessage `json:"next_date,omitempty"`
	NextN       *[]string       `json:"next_n,omitempty"`
	NextNCount  int             `json:"next_n_count,omitempty"`
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

	for _, tc := range decodeCases[ParseErrorTest](t, spec.ParseErrors, "input", "error_contains") {
		t.Run(tc.Name, func(t *testing.T) {
			_, err := ParseSchedule(tc.Input)
			if err == nil {
				t.Fatalf("expected parse error for %q (%s)", tc.Input, tc.Description)
			}
			if Validate(tc.Input) {
				t.Errorf("Validate(%q) = true, want false", tc.Input)
			}
			if !strings.Contains(err.Error(), tc.ErrorContains) {
				t.Errorf("parse error for %q is %q, want it to contain %q", tc.Input, err, tc.ErrorContains)
			}
		})
	}
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
						expectedN := *tc.NextN
						n := len(expectedN)
						if tc.NextNCount > 0 {
							n = tc.NextNCount
						}
						results := s.NextNFrom(now, n)

						if len(results) != len(expectedN) {
							t.Errorf("NextNFrom() returned %d results, want %d", len(results), len(expectedN))
						} else {
							for i, expectedStr := range expectedN {
								expected, err := parseZonedDateTime(expectedStr)
								if err != nil {
									t.Fatalf("failed to parse expected[%d] %q: %v", i, expectedStr, err)
								}
								if !results[i].Equal(expected) {
									t.Errorf("NextNFrom()[%d] = %v, want %v", i, results[i], expected)
								}
							}
						}
					}

					if tc.NextNLength != nil {
						results := s.NextNFrom(now, tc.NextNCount)
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

			if len(results) != len(expectedList) {
				t.Errorf("Occurrences() returned %d results, want %d", len(results), len(expectedList))
			} else {
				for i, expectedStr := range expectedList {
					expected, err := parseZonedDateTime(expectedStr)
					if err != nil {
						t.Fatalf("failed to parse expected[%d] %q: %v", i, expectedStr, err)
					}
					if !results[i].Equal(expected) {
						t.Errorf("Occurrences()[%d] = %v, want %v", i, results[i], expected)
					}
				}
			}
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
				expectedList := *tc.Expected
				if len(results) != len(expectedList) {
					t.Errorf("Between() returned %d results, want %d", len(results), len(expectedList))
				} else {
					for i, expectedStr := range expectedList {
						expected, err := parseZonedDateTime(expectedStr)
						if err != nil {
							t.Fatalf("failed to parse expected[%d] %q: %v", i, expectedStr, err)
						}
						if !results[i].Equal(expected) {
							t.Errorf("Between()[%d] = %v, want %v", i, results[i], expected)
						}
					}
				}
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

func expectedTimestamp(t *testing.T, raw json.RawMessage) *time.Time {
	if strings.TrimSpace(string(raw)) == "null" {
		return nil
	}
	var str string
	if err := json.Unmarshal(raw, &str); err != nil {
		t.Fatalf("failed to read expected timestamp %s: %v", raw, err)
	}
	expected, err := parseZonedDateTime(str)
	if err != nil {
		t.Fatalf("failed to parse expected timestamp %q: %v", str, err)
	}
	return &expected
}

func checkTimestamp(t *testing.T, call string, got, want *time.Time) {
	switch {
	case want == nil && got != nil:
		t.Errorf("%s = %v, want nil", call, *got)
	case want != nil && got == nil:
		t.Errorf("%s = nil, want %v", call, *want)
	case want != nil && !got.Equal(*want):
		t.Errorf("%s = %v, want %v", call, *got, *want)
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
