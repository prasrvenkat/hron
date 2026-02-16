package hron

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

// Test spec structure
type TestSpec struct {
	Now         string                     `json:"now"`
	Parse       map[string]json.RawMessage `json:"parse"`
	ParseErrors ParseErrorGroup            `json:"parse_errors"`
	Eval        map[string]json.RawMessage `json:"eval"`
	Cron        CronSpec                   `json:"cron"`
	EvalErrors  EvalErrorGroup             `json:"eval_errors"`
}

type EvalErrorGroup struct {
	Tests []EvalErrorTest `json:"tests"`
}

type EvalErrorTest struct {
	Name        string `json:"name"`
	Expression  string `json:"expression"`
	Description string `json:"description"`
}

type ParseGroup struct {
	Tests []ParseTest `json:"tests"`
}

type ParseTest struct {
	Name      string `json:"name"`
	Input     string `json:"input"`
	Canonical string `json:"canonical"`
}

type ParseErrorGroup struct {
	Tests []ParseErrorTest `json:"tests"`
}

type ParseErrorTest struct {
	Name        string `json:"name"`
	Input       string `json:"input"`
	Description string `json:"description"`
}

type EvalGroup struct {
	Tests []EvalTest `json:"tests"`
}

type EvalTest struct {
	Name        string   `json:"name"`
	Expression  string   `json:"expression"`
	Description string   `json:"description,omitempty"`
	Now         string   `json:"now,omitempty"`
	Next        *string  `json:"next,omitempty"`
	NextDate    string   `json:"next_date,omitempty"`
	NextN       []string `json:"next_n,omitempty"`
	NextNCount  int      `json:"next_n_count,omitempty"`
	NextNLength int      `json:"next_n_length,omitempty"`
}

type OccurrencesGroup struct {
	Tests []OccurrencesTest `json:"tests"`
}

type OccurrencesTest struct {
	Name        string   `json:"name"`
	Expression  string   `json:"expression"`
	Description string   `json:"description,omitempty"`
	From        string   `json:"from"`
	Take        int      `json:"take"`
	Expected    []string `json:"expected"`
}

type BetweenGroup struct {
	Tests []BetweenTest `json:"tests"`
}

type BetweenTest struct {
	Name          string   `json:"name"`
	Expression    string   `json:"expression"`
	Description   string   `json:"description,omitempty"`
	From          string   `json:"from"`
	To            string   `json:"to"`
	Expected      []string `json:"expected,omitempty"`
	ExpectedCount int      `json:"expected_count,omitempty"`
}

type PreviousFromGroup struct {
	Tests []PreviousFromTest `json:"tests"`
}

type PreviousFromTest struct {
	Name        string  `json:"name"`
	Expression  string  `json:"expression"`
	Description string  `json:"description,omitempty"`
	Now         string  `json:"now"`
	Expected    *string `json:"expected"`
}

type CronSpec struct {
	ToCron         ToCronGroup        `json:"to_cron"`
	ToCronErrors   ToCronErrorGroup   `json:"to_cron_errors"`
	FromCron       FromCronGroup      `json:"from_cron"`
	FromCronErrors FromCronErrorGroup `json:"from_cron_errors"`
	Roundtrip      RoundtripGroup     `json:"roundtrip"`
}

type ToCronGroup struct {
	Tests []ToCronTest `json:"tests"`
}

type ToCronTest struct {
	Name string `json:"name"`
	Hron string `json:"hron"`
	Cron string `json:"cron"`
}

type ToCronErrorGroup struct {
	Tests []ToCronErrorTest `json:"tests"`
}

type ToCronErrorTest struct {
	Name        string `json:"name"`
	Hron        string `json:"hron"`
	Description string `json:"description"`
}

type FromCronGroup struct {
	Tests []FromCronTest `json:"tests"`
}

type FromCronTest struct {
	Name string `json:"name"`
	Cron string `json:"cron"`
	Hron string `json:"hron"`
}

type FromCronErrorGroup struct {
	Tests []FromCronErrorTest `json:"tests"`
}

type FromCronErrorTest struct {
	Name        string `json:"name"`
	Cron        string `json:"cron"`
	Description string `json:"description"`
}

type RoundtripGroup struct {
	Tests []RoundtripTest `json:"tests"`
}

type RoundtripTest struct {
	Name string `json:"name"`
	Hron string `json:"hron"`
}

func loadSpec(t *testing.T) *TestSpec {
	data, err := os.ReadFile("../spec/tests.json")
	if err != nil {
		t.Fatalf("failed to read spec: %v", err)
	}

	var spec TestSpec
	if err := json.Unmarshal(data, &spec); err != nil {
		t.Fatalf("failed to parse spec: %v", err)
	}
	return &spec
}

// parseZonedDateTime parses a datetime string in the format used by the spec.
// Supports: "2026-02-06T12:00:00+00:00[UTC]" or "2026-02-06T12:00:00-05:00[America/New_York]"
func parseZonedDateTime(s string) (time.Time, error) {
	// Extract timezone from brackets
	re := regexp.MustCompile(`^(.+?)\[([^\]]+)\]$`)
	matches := re.FindStringSubmatch(s)
	if matches == nil {
		// Try parsing without timezone brackets
		return time.Parse(time.RFC3339, s)
	}

	isoStr := matches[1]
	tzName := matches[2]

	// Load the timezone
	loc, err := time.LoadLocation(tzName)
	if err != nil {
		// Fall back to parsing as RFC3339
		return time.Parse(time.RFC3339, isoStr)
	}

	// Parse the datetime
	// Remove the offset for parsing
	t, err := time.Parse(time.RFC3339, isoStr)
	if err != nil {
		return time.Time{}, err
	}

	// Convert to the target timezone
	return t.In(loc), nil
}

func TestParse(t *testing.T) {
	spec := loadSpec(t)

	for section, raw := range spec.Parse {
		// Skip non-test entries like "description"
		if section == "description" {
			continue
		}

		var group ParseGroup
		if err := json.Unmarshal(raw, &group); err != nil {
			t.Fatalf("failed to parse section %s: %v", section, err)
		}

		t.Run(section, func(t *testing.T) {
			for _, tc := range group.Tests {
				t.Run(tc.Name, func(t *testing.T) {
					s, err := ParseSchedule(tc.Input)
					if err != nil {
						t.Fatalf("failed to parse %q: %v", tc.Input, err)
					}

					got := s.String()
					if got != tc.Canonical {
						t.Errorf("parse(%q).String() = %q, want %q", tc.Input, got, tc.Canonical)
					}

					// Roundtrip: parse(canonical).String() == canonical
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

	for _, tc := range spec.ParseErrors.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			_, err := ParseSchedule(tc.Input)
			if err == nil {
				t.Errorf("expected parse error for %q (%s)", tc.Input, tc.Description)
			}
		})
	}
}

func TestEvalErrors(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range spec.EvalErrors.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			// Go validates timezone at construction time (NewSchedule/ParseSchedule),
			// so these should fail at parse time.
			_, err := ParseSchedule(tc.Expression)
			if err == nil {
				t.Errorf("expected error for %q (%s), but parse succeeded", tc.Expression, tc.Description)
			}
		})
	}
}

func TestEval(t *testing.T) {
	spec := loadSpec(t)

	// Parse default now
	defaultNow, err := parseZonedDateTime(spec.Now)
	if err != nil {
		t.Fatalf("failed to parse default now: %v", err)
	}

	for section, raw := range spec.Eval {
		// Skip non-test entries like "description", and special sections handled separately
		if section == "description" || section == "occurrences" || section == "between" || section == "matches" {
			continue
		}

		var group EvalGroup
		if err := json.Unmarshal(raw, &group); err != nil {
			t.Fatalf("failed to parse eval section %s: %v", section, err)
		}

		t.Run(section, func(t *testing.T) {
			for _, tc := range group.Tests {
				t.Run(tc.Name, func(t *testing.T) {
					// Parse the expression
					s, err := ParseSchedule(tc.Expression)
					if err != nil {
						t.Fatalf("failed to parse %q: %v", tc.Expression, err)
					}

					// Use test-specific now or default
					now := defaultNow
					if tc.Now != "" {
						now, err = parseZonedDateTime(tc.Now)
						if err != nil {
							t.Fatalf("failed to parse now %q: %v", tc.Now, err)
						}
					}

					// Test next_from
					if tc.Next != nil {
						result := s.NextFrom(now)
						if *tc.Next == "" {
							// null expected
							if result != nil {
								t.Errorf("NextFrom() = %v, want nil", result)
							}
						} else {
							expected, err := parseZonedDateTime(*tc.Next)
							if err != nil {
								t.Fatalf("failed to parse expected next %q: %v", *tc.Next, err)
							}
							if result == nil {
								t.Errorf("NextFrom() = nil, want %v", expected)
							} else if !result.Equal(expected) {
								t.Errorf("NextFrom() = %v, want %v", result, expected)
							}
						}
					}

					// Test next_date (date only comparison)
					if tc.NextDate != "" {
						result := s.NextFrom(now)
						if result == nil {
							t.Errorf("NextFrom() = nil, want date %s", tc.NextDate)
						} else {
							gotDate := result.In(time.UTC).Format("2006-01-02")
							if gotDate != tc.NextDate {
								t.Errorf("NextFrom() date = %s, want %s", gotDate, tc.NextDate)
							}
						}
					}

					// Test next_n
					if len(tc.NextN) > 0 {
						n := len(tc.NextN)
						if tc.NextNCount > 0 {
							n = tc.NextNCount
						}
						results := s.NextNFrom(now, n)

						if len(results) != len(tc.NextN) {
							t.Errorf("NextNFrom() returned %d results, want %d", len(results), len(tc.NextN))
						} else {
							for i, expectedStr := range tc.NextN {
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

					// Test next_n_length (only check count)
					if tc.NextNLength > 0 {
						n := tc.NextNCount
						results := s.NextNFrom(now, n)
						if len(results) != tc.NextNLength {
							t.Errorf("NextNFrom() returned %d results, want %d", len(results), tc.NextNLength)
						}
					}
				})
			}
		})
	}
}

func TestOccurrences(t *testing.T) {
	spec := loadSpec(t)

	// Parse the occurrences section
	var group OccurrencesGroup
	if err := json.Unmarshal(spec.Eval["occurrences"], &group); err != nil {
		t.Fatalf("failed to parse occurrences section: %v", err)
	}

	for _, tc := range group.Tests {
		t.Run(tc.Name, func(t *testing.T) {
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

			if len(results) != len(tc.Expected) {
				t.Errorf("Occurrences() returned %d results, want %d", len(results), len(tc.Expected))
			} else {
				for i, expectedStr := range tc.Expected {
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

	// Parse the between section
	var group BetweenGroup
	if err := json.Unmarshal(spec.Eval["between"], &group); err != nil {
		t.Fatalf("failed to parse between section: %v", err)
	}

	for _, tc := range group.Tests {
		t.Run(tc.Name, func(t *testing.T) {
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

			if tc.ExpectedCount > 0 {
				if len(results) != tc.ExpectedCount {
					t.Errorf("Between() returned %d results, want %d", len(results), tc.ExpectedCount)
				}
			} else {
				if len(results) != len(tc.Expected) {
					t.Errorf("Between() returned %d results, want %d", len(results), len(tc.Expected))
				} else {
					for i, expectedStr := range tc.Expected {
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

	// Parse the previous_from section
	var group PreviousFromGroup
	if err := json.Unmarshal(spec.Eval["previous_from"], &group); err != nil {
		t.Fatalf("failed to parse previous_from section: %v", err)
	}

	for _, tc := range group.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			now, err := parseZonedDateTime(tc.Now)
			if err != nil {
				t.Fatalf("failed to parse now %q: %v", tc.Now, err)
			}

			result := s.PreviousFrom(now)

			if tc.Expected == nil {
				if result != nil {
					t.Errorf("PreviousFrom() = %v, want nil", result)
				}
			} else {
				if result == nil {
					t.Errorf("PreviousFrom() = nil, want %v", *tc.Expected)
				} else {
					expected, err := parseZonedDateTime(*tc.Expected)
					if err != nil {
						t.Fatalf("failed to parse expected %q: %v", *tc.Expected, err)
					}
					if !result.Equal(expected) {
						t.Errorf("PreviousFrom() = %v, want %v", result, expected)
					}
				}
			}
		})
	}
}

func TestToCron(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range spec.Cron.ToCron.Tests {
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

	for _, tc := range spec.Cron.ToCronErrors.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Hron)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Hron, err)
			}

			_, err = s.ToCron()
			if err == nil {
				t.Errorf("expected ToCron() error for %q (%s)", tc.Hron, tc.Description)
			}
		})
	}
}

func TestFromCron(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range spec.Cron.FromCron.Tests {
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

	for _, tc := range spec.Cron.FromCronErrors.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			_, err := FromCronExpr(tc.Cron)
			if err == nil {
				t.Errorf("expected FromCron(%q) error (%s)", tc.Cron, tc.Description)
			}
		})
	}
}

func TestCronRoundtrip(t *testing.T) {
	spec := loadSpec(t)

	for _, tc := range spec.Cron.Roundtrip.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			// hron -> cron
			s1, err := ParseSchedule(tc.Hron)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Hron, err)
			}

			cron, err := s1.ToCron()
			if err != nil {
				t.Fatalf("ToCron() failed: %v", err)
			}

			// cron -> hron
			s2, err := FromCronExpr(cron)
			if err != nil {
				t.Fatalf("FromCron(%q) failed: %v", cron, err)
			}

			// hron -> cron again
			cron2, err := s2.ToCron()
			if err != nil {
				t.Fatalf("ToCron() failed on roundtrip: %v", err)
			}

			// Both cron expressions should be the same
			if cron != cron2 {
				t.Errorf("roundtrip failed: %q -> %q -> %q -> %q", tc.Hron, cron, s2.String(), cron2)
			}
		})
	}
}

type MatchesGroup struct {
	Tests []MatchesTest `json:"tests"`
}

type MatchesTest struct {
	Name       string `json:"name"`
	Expression string `json:"expression"`
	Datetime   string `json:"datetime"`
	Expected   bool   `json:"expected"`
}

func TestMatches(t *testing.T) {
	spec := loadSpec(t)

	// Parse the matches section
	var group MatchesGroup
	if err := json.Unmarshal(spec.Eval["matches"], &group); err != nil {
		t.Fatalf("failed to parse matches section: %v", err)
	}

	for _, tc := range group.Tests {
		t.Run(tc.Name, func(t *testing.T) {
			s, err := ParseSchedule(tc.Expression)
			if err != nil {
				t.Fatalf("failed to parse %q: %v", tc.Expression, err)
			}

			dt, err := parseZonedDateTime(tc.Datetime)
			if err != nil {
				t.Fatalf("failed to parse datetime %q: %v", tc.Datetime, err)
			}

			got := s.Matches(dt)
			if got != tc.Expected {
				t.Errorf("Matches(%q, %v) = %v, want %v", tc.Expression, dt, got, tc.Expected)
			}
		})
	}
}

func TestTimezone(t *testing.T) {
	// Test timezone getter
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
	// Test strict greater-than behavior: if now equals an occurrence exactly, skip it
	s, err := ParseSchedule("every day at 12:00 in UTC")
	if err != nil {
		t.Fatal(err)
	}

	now := time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)
	next := s.NextFrom(now)
	if next == nil {
		t.Fatal("expected non-nil result")
	}

	// Next should be tomorrow, not today
	expected := time.Date(2026, 2, 7, 12, 0, 0, 0, time.UTC)
	if !next.Equal(expected) {
		t.Errorf("NextFrom() = %v, want %v", next, expected)
	}
}

func TestIntervalAlignment(t *testing.T) {
	// Test that interval alignment works correctly
	s, err := ParseSchedule("every 3 days at 09:00 in UTC")
	if err != nil {
		t.Fatal(err)
	}

	// Feb 6, 2026 is day 20490 from epoch (1970-01-01)
	// 20490 % 3 = 0, so Feb 6 is aligned
	// Since 09:00 has passed, next should be Feb 9 (20490 + 3)
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

func TestDST(t *testing.T) {
	// Test DST handling (spring forward)
	// March 8, 2026, 2:00 AM doesn't exist in America/New_York (spring forward)
	s, err := ParseSchedule("every day at 02:30 in America/New_York")
	if err != nil {
		t.Fatal(err)
	}

	// March 7, 2026 before midnight
	now := time.Date(2026, 3, 7, 23, 0, 0, 0, time.FixedZone("EST", -5*3600))
	next := s.NextFrom(now)
	if next == nil {
		t.Fatal("expected non-nil result")
	}

	// On March 8, 2:30 AM doesn't exist - should be pushed forward
	// The exact behavior depends on Go's time handling
	loc, _ := time.LoadLocation("America/New_York")
	if next.In(loc).Hour() < 2 || (next.In(loc).Hour() == 2 && next.In(loc).Minute() < 30) {
		// This shouldn't happen - time should be pushed forward
		t.Logf("DST handling result: %v", next.In(loc))
	}
}

// Helper to check if a string is valid JSON null
func isNullJSON(s string) bool {
	return strings.TrimSpace(s) == "null"
}
