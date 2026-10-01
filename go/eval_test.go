package hron

import (
	"fmt"
	"testing"
	"time"
)

var friday = time.Date(2026, 2, 6, 12, 0, 0, 0, time.UTC)

func formatOrNil(t *time.Time) string {
	if t == nil {
		return "nil"
	}
	return t.UTC().Format(time.RFC3339)
}

func mustSchedule(t *testing.T, data *ScheduleData) *Schedule {
	t.Helper()
	s, err := NewSchedule(data)
	if err != nil {
		t.Fatalf("NewSchedule: %v", err)
	}
	return s
}

// The parser accepts intervals from 1 to 2147483647; a schedule built by hand
// treats one below 1 as 1 and one above as 2147483647.
func TestHandBuiltIntervals(t *testing.T) {
	nine := []TimeOfDay{{9, 0}}
	cases := []struct {
		name       string
		expr       func(interval int) ScheduleExpr
		interval   int
		next, prev string
	}{
		{"week", weekOnMonday, 0, "2026-02-09T09:00:00Z", "2026-02-02T09:00:00Z"},
		{"week", weekOnMonday, -3, "2026-02-09T09:00:00Z", "2026-02-02T09:00:00Z"},
		{"week", weekOnMonday, 1<<62 + 7, "nil", "1970-01-05T09:00:00Z"},
		{"minutes", minutesFromNine, 0, "2026-02-07T09:00:00Z", "2026-02-06T10:00:00Z"},
		{"minutes", minutesFromNine, -3, "2026-02-07T09:00:00Z", "2026-02-06T10:00:00Z"},
		{"minutes", minutesFromNine, 1<<62 + 7, "2026-02-07T09:00:00Z", "2026-02-06T09:00:00Z"},
		{"hours", hoursFromNine, 1 << 58, "2026-02-07T09:00:00Z", "2026-02-06T09:00:00Z"},
		{"day", func(n int) ScheduleExpr { return NewDayRepeat(n, NewDayFilterEvery(), nine) }, 1<<62 + 7, "nil", "1970-01-01T09:00:00Z"},
	}
	for _, c := range cases {
		t.Run(fmt.Sprintf("%s %d", c.name, c.interval), func(t *testing.T) {
			s := mustSchedule(t, NewScheduleData(c.expr(c.interval)))
			if got := formatOrNil(s.NextFrom(friday)); got != c.next {
				t.Errorf("NextFrom = %s, want %s", got, c.next)
			}
			if got := formatOrNil(s.PreviousFrom(friday)); got != c.prev {
				t.Errorf("PreviousFrom = %s, want %s", got, c.prev)
			}
		})
	}
}

func weekOnMonday(interval int) ScheduleExpr {
	return NewWeekRepeat(interval, []Weekday{Monday}, []TimeOfDay{{9, 0}})
}

func minutesFromNine(interval int) ScheduleExpr {
	return NewIntervalRepeat(interval, IntervalMin, TimeOfDay{9, 0}, TimeOfDay{10, 0}, nil)
}

func hoursFromNine(interval int) ScheduleExpr {
	return NewIntervalRepeat(interval, IntervalHours, TimeOfDay{9, 0}, TimeOfDay{10, 0}, nil)
}
