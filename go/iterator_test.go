package hron

import (
	"slices"
	"testing"
	"time"
)

// =============================================================================
// Laziness Tests
// =============================================================================

func TestOccurrencesIsLazy(t *testing.T) {
	// An unbounded schedule should not hang or OOM when creating the iterator
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Creating the iterator should be instant (lazy)
	iter := s.Occurrences(from)

	// Taking just 1 should work without evaluating the rest
	count := 0
	for range iter {
		count++
		if count >= 1 {
			break
		}
	}

	if count != 1 {
		t.Errorf("expected 1 occurrence, got %d", count)
	}
}

func TestBetweenIsLazy(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")
	to, _ := time.Parse(time.RFC3339, "2026-12-31T23:59:00Z")

	// Creating the iterator should be instant
	iter := s.Between(from, to)

	// Taking just 3 should not evaluate all ~330 days
	count := 0
	for range iter {
		count++
		if count >= 3 {
			break
		}
	}

	if count != 3 {
		t.Errorf("expected 3 occurrences, got %d", count)
	}
}

// =============================================================================
// Early Termination Tests
// =============================================================================

func TestOccurrencesEarlyTerminationWithBreak(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	count := 0
	for range s.Occurrences(from) {
		count++
		if count >= 5 {
			break
		}
	}

	if count != 5 {
		t.Errorf("expected 5 occurrences, got %d", count)
	}
}

func TestOccurrencesEarlyTerminationWithCondition(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")
	cutoff, _ := time.Parse(time.RFC3339, "2026-02-05T00:00:00Z")

	var results []time.Time
	for dt := range s.Occurrences(from) {
		if !dt.Before(cutoff) {
			break
		}
		results = append(results, dt)
	}

	// Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
	if len(results) != 4 {
		t.Errorf("expected 4 occurrences, got %d", len(results))
	}
}

func TestOccurrencesFindSaturday(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Find the first Saturday occurrence
	var saturday time.Time
	for dt := range s.Occurrences(from) {
		if dt.Weekday() == time.Saturday {
			saturday = dt
			break
		}
	}

	// Feb 7, 2026 is a Saturday
	if saturday.Day() != 7 {
		t.Errorf("expected day 7, got %d", saturday.Day())
	}
}

// =============================================================================
// Range-over-func Patterns
// =============================================================================

func TestRangeOverFuncWithIndex(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Using index manually in range-over-func
	idx := 0
	for dt := range s.Occurrences(from) {
		if idx >= 3 {
			break
		}
		expectedDay := idx + 1
		if dt.Day() != expectedDay {
			t.Errorf("occurrence %d: expected day %d, got %d", idx, expectedDay, dt.Day())
		}
		idx++
	}
}

func TestOccurrencesForLoop(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	count := 0
	for dt := range s.Occurrences(from) {
		count++
		if dt.Day() >= 5 {
			break
		}
	}

	if count != 5 {
		t.Errorf("expected 5, got %d", count)
	}
}

func TestBetweenForLoop(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")
	to, _ := time.Parse(time.RFC3339, "2026-02-03T23:59:00Z")

	var days []int
	for dt := range s.Between(from, to) {
		days = append(days, dt.Day())
	}

	expected := []int{1, 2, 3}
	if !slices.Equal(days, expected) {
		t.Errorf("expected %v, got %v", expected, days)
	}
}

// =============================================================================
// slices.Collect Integration
// =============================================================================

func TestOccurrencesCollectWithSlices(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 until 2026-02-05 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	results := slices.Collect(s.Occurrences(from))

	if len(results) != 5 {
		t.Errorf("expected 5 occurrences, got %d", len(results))
	}
}

func TestBetweenCollectWithSlices(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")
	to, _ := time.Parse(time.RFC3339, "2026-02-07T23:59:00Z")

	results := slices.Collect(s.Between(from, to))

	if len(results) != 7 {
		t.Errorf("expected 7 occurrences, got %d", len(results))
	}
}

// =============================================================================
// Edge Cases
// =============================================================================

func TestOccurrencesEmptyWhenPastUntil(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 until 2026-01-01 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	count := 0
	for range s.Occurrences(from) {
		count++
		if count >= 10 {
			break
		}
	}

	if count != 0 {
		t.Errorf("expected 0 occurrences, got %d", count)
	}
}

func TestBetweenEmptyRange(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T12:00:00Z")
	to, _ := time.Parse(time.RFC3339, "2026-02-01T13:00:00Z")

	results := slices.Collect(s.Between(from, to))

	if len(results) != 0 {
		t.Errorf("expected 0 occurrences, got %d", len(results))
	}
}

func TestOccurrencesSingleDateTerminates(t *testing.T) {
	s, err := ParseSchedule("on 2026-02-14 at 14:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	count := 0
	for range s.Occurrences(from) {
		count++
		if count >= 100 {
			break
		}
	}

	if count != 1 {
		t.Errorf("expected 1 occurrence, got %d", count)
	}
}

// =============================================================================
// Timezone Handling
// =============================================================================

func TestOccurrencesPreservesTimezone(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in America/New_York")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	loc, _ := time.LoadLocation("America/New_York")
	from := time.Date(2026, 2, 1, 0, 0, 0, 0, loc)

	count := 0
	for dt := range s.Occurrences(from) {
		// Check timezone is preserved
		zoneName, _ := dt.Zone()
		if zoneName != "EST" && zoneName != "EDT" {
			t.Errorf("expected EST or EDT, got %s", zoneName)
		}
		count++
		if count >= 3 {
			break
		}
	}
}

func TestBetweenHandlesDSTTransition(t *testing.T) {
	// March 8, 2026 is DST spring forward in America/New_York
	// 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
	s, err := ParseSchedule("every day at 02:30 in America/New_York")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	loc, _ := time.LoadLocation("America/New_York")
	from := time.Date(2026, 3, 7, 0, 0, 0, 0, loc)
	to := time.Date(2026, 3, 10, 0, 0, 0, 0, loc)

	results := slices.Collect(s.Between(from, to))

	// Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
	if len(results) != 3 {
		t.Errorf("expected 3 occurrences, got %d", len(results))
	}
	if results[0].Hour() != 2 {
		t.Errorf("expected hour 2 for Mar 7, got %d", results[0].Hour())
	}
	if results[1].Hour() != 3 {
		t.Errorf("expected hour 3 for Mar 8 (DST shift), got %d", results[1].Hour())
	}
	if results[2].Hour() != 2 {
		t.Errorf("expected hour 2 for Mar 9, got %d", results[2].Hour())
	}
}

// =============================================================================
// Multiple Times Per Day
// =============================================================================

func TestOccurrencesMultipleTimesPerDay(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00, 12:00, 17:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	var results []time.Time
	for dt := range s.Occurrences(from) {
		results = append(results, dt)
		if len(results) >= 9 { // 3 days worth
			break
		}
	}

	if len(results) != 9 {
		t.Errorf("expected 9 occurrences, got %d", len(results))
	}
	// First day: 09:00, 12:00, 17:00
	if results[0].Hour() != 9 {
		t.Errorf("expected hour 9, got %d", results[0].Hour())
	}
	if results[1].Hour() != 12 {
		t.Errorf("expected hour 12, got %d", results[1].Hour())
	}
	if results[2].Hour() != 17 {
		t.Errorf("expected hour 17, got %d", results[2].Hour())
	}
}

// =============================================================================
// Complex Iteration Patterns
// =============================================================================

func TestComplexIterationChain(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Complex chain: skip weekends, take first 5 weekdays, get their day numbers
	var weekdayDays []int
	count := 0
	for dt := range s.Occurrences(from) {
		if count >= 14 { // Two weeks to ensure we have enough
			break
		}
		count++

		dow := dt.Weekday()
		if dow >= time.Monday && dow <= time.Friday {
			weekdayDays = append(weekdayDays, dt.Day())
			if len(weekdayDays) >= 5 {
				break
			}
		}
	}

	// Feb 2026: 2,3,4,5,6 are Mon-Fri
	expected := []int{2, 3, 4, 5, 6}
	if !slices.Equal(weekdayDays, expected) {
		t.Errorf("expected %v, got %v", expected, weekdayDays)
	}
}

// =============================================================================
// Filter-like Patterns
// =============================================================================

func TestFilterWeekends(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Filter to only weekends from first 14 days
	var weekends []time.Time
	count := 0
	for dt := range s.Occurrences(from) {
		if count >= 14 {
			break
		}
		count++

		dow := dt.Weekday()
		if dow == time.Saturday || dow == time.Sunday {
			weekends = append(weekends, dt)
		}
	}

	// 2 weekends in 2 weeks = 4 days
	if len(weekends) != 4 {
		t.Errorf("expected 4 weekend days, got %d", len(weekends))
	}
}

func TestMapToDays(t *testing.T) {
	s, err := ParseSchedule("every day at 09:00 in UTC")
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}

	from, _ := time.Parse(time.RFC3339, "2026-02-01T00:00:00Z")

	// Map to just the day number
	var days []int
	count := 0
	for dt := range s.Occurrences(from) {
		days = append(days, dt.Day())
		count++
		if count >= 5 {
			break
		}
	}

	expected := []int{1, 2, 3, 4, 5}
	if !slices.Equal(days, expected) {
		t.Errorf("expected %v, got %v", expected, days)
	}
}
