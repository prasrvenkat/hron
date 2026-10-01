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

// Parse requires starting with a named until; a schedule built without one
// resolves it from the epoch.
func TestHandBuiltNamedUntilWithoutStarting(t *testing.T) {
	data := NewScheduleData(NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{9, 0}}))
	until := NewNamedUntil(Mar, 1)
	data.Until = &until
	s := mustSchedule(t, data)
	if got := formatOrNil(s.PreviousFrom(friday)); got != "1970-03-01T09:00:00Z" {
		t.Errorf("PreviousFrom = %s, want 1970-03-01T09:00:00Z", got)
	}
}

// A named until that names no real date bounds nothing.
func TestHandBuiltNamedUntilWithNoSuchDate(t *testing.T) {
	data := NewScheduleData(NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{9, 0}}))
	until := NewNamedUntil(Feb, 30)
	data.Until = &until
	s := mustSchedule(t, data)
	if got := formatOrNil(s.NextFrom(friday)); got != "2026-02-07T09:00:00Z" {
		t.Errorf("NextFrom = %s, want 2026-02-07T09:00:00Z", got)
	}
}

// Amsterdam's local mean time, +00:19:32, carries seconds, so the minute is
// cut on the wall clock, not on the instant. The spec leaves sub-minute
// offsets out (spec/README.md, "Timezone data"), so this is a Go test.
func TestMatchesDropsSecondsOnTheWallClock(t *testing.T) {
	s := MustParse("every day at 09:00 in Europe/Amsterdam")
	amsterdam, err := time.LoadLocation("Europe/Amsterdam")
	if err != nil {
		t.Fatal(err)
	}
	if !s.Matches(time.Date(1900, 6, 1, 9, 0, 10, 0, amsterdam)) {
		t.Error("Matches(1900-06-01 09:00:10 local) = false, want true")
	}
}

// Slot keys never decrease in wall-clock order, a slot a gap skips is keyed
// at the instant its gap ends, and the bounded binary search finds what a scan
// of every slot finds, on the dates around transitions: a spring-forward gap,
// a fall-back overlap, at midnight (Sao Paulo), of half an hour (Lord Howe),
// of a whole day (Apia, 2011), and of 28 seconds, from an offset that carries
// seconds (Amsterdam, 1937).
func TestSlotSearchAroundTransitions(t *testing.T) {
	zones := map[string]int{
		"America/New_York":    2026,
		"America/Sao_Paulo":   2018,
		"Australia/Lord_Howe": 2026,
		"Pacific/Apia":        2011,
		"Europe/Amsterdam":    1937,
	}
	for name, year := range zones {
		zone, err := time.LoadLocation(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, transition := range transitionsIn(zone, year) {
			for _, step := range []int{7, 30, 90} {
				s := search{zone: zone, times: dailyTimes{slots: slots{from: 0, step: step, count: (minutesPerDay-1)/step + 1}}}
				checkSlotSearch(t, &s, transition)
			}
		}
	}
}

// transitionsIn returns the instants in year where zone's offset changes.
func transitionsIn(zone *time.Location, year int) []time.Time {
	var transitions []time.Time
	end := time.Date(year+1, 1, 1, 0, 0, 0, 0, time.UTC)
	for t := time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC); t.Before(end); t = t.Add(time.Hour) {
		if offsetAt(t, zone) != offsetAt(t.Add(time.Hour), zone) {
			lo, hi := t.Unix(), t.Add(time.Hour).Unix()
			for hi-lo > 1 {
				mid := lo + (hi-lo)/2
				if offsetAt(time.Unix(mid, 0), zone) == offsetAt(t, zone) {
					lo = mid
				} else {
					hi = mid
				}
			}
			transitions = append(transitions, time.Unix(hi, 0))
		}
	}
	return transitions
}

func checkSlotSearch(t *testing.T, s *search, transition time.Time) {
	t.Helper()
	slots := s.times.slots
	nowDate := dateOf(transition.In(s.zone))
	for day := -2; day <= 2; day++ {
		date := addDays(nowDate, day)
		all := make([]slot, slots.count)
		for k := range all {
			all[k] = slotOn(date, slots.minute(k), s.zone)
			if k > 0 && all[k].key.Before(all[k-1].key) {
				t.Fatalf("%s %s step %d: key of slot %d (%s) before slot %d's (%s)", s.zone, date.Format(time.DateOnly), slots.step, k, all[k].key, k-1, all[k-1].key)
			}
			if all[k].skipped && (!all[k].key.Equal(transition) || !all[k].instant.IsZero()) {
				t.Fatalf("%s %s step %d: skipped slot %d keyed %s, want %s", s.zone, date.Format(time.DateOnly), slots.step, k, all[k].key, transition)
			}
		}
		for now := transition.Add(-30 * time.Hour); now.Before(transition.Add(30 * time.Hour)); now = now.Add(13 * time.Minute) {
			now := now.In(s.zone)
			for _, d := range []direction{forward, backward} {
				var want time.Time
				found := false
				for _, slot := range all {
					if !slot.skipped && d.precedes(now, slot.instant) && (!found || d.precedes(slot.instant, want)) {
						want, found = slot.instant, true
					}
				}
				got, ok := s.nearestSlot(date, now, d)
				if ok != found || !got.Equal(want) {
					t.Fatalf("%s %s step %d from %s direction %d: got %s %v, want %s %v", s.zone, date.Format(time.DateOnly), slots.step, now, d, got, ok, want, found)
				}
			}
		}
	}
}
