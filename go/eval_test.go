package hron

import (
	"math"
	"slices"
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

// The parser's largest intervals step periods past 32 bits; run with GOARCH=386 too.
func TestLargestIntervalsOn32Bit(t *testing.T) {
	yearOne := time.Date(1, 6, 1, 0, 0, 0, 0, time.UTC)
	cases := []struct {
		expression string
		now        time.Time
		next, prev string
	}{
		{"every 306783379 weeks on monday at 09:00", friday, "nil", "1970-01-05T09:00:00Z"},
		{"every 613566757 weeks on monday at 09:00", friday, "nil", "1970-01-05T09:00:00Z"},
		{"every 2147483647 years on jan 1 at 09:00", yearOne, "1970-01-01T09:00:00Z", "nil"},
		{"every 2147483647 months on the 1st at 09:00", friday, "nil", "1970-01-01T09:00:00Z"},
		{"every 2147483647 days at 09:00", friday, "nil", "1970-01-01T09:00:00Z"},
		{"every 2147483647 hours from 09:00 to 10:00", friday, "2026-02-07T09:00:00Z", "2026-02-06T09:00:00Z"},
	}
	for _, c := range cases {
		t.Run(c.expression, func(t *testing.T) {
			s := MustParse(c.expression)
			if got := formatOrNil(s.NextFrom(c.now)); got != c.next {
				t.Errorf("NextFrom = %s, want %s", got, c.next)
			}
			if got := formatOrNil(s.PreviousFrom(c.now)); got != c.prev {
				t.Errorf("PreviousFrom = %s, want %s", got, c.prev)
			}
		})
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
// of a whole day (Apia, 2011), of 28 seconds, from an offset that carries
// seconds (Amsterdam, 1937), and after the date ends in UTC, in a zone west of
// it (Nuuk, 2022).
func TestSlotSearchAroundTransitions(t *testing.T) {
	zones := map[string]int{
		"America/New_York":    2026,
		"America/Sao_Paulo":   2018,
		"Australia/Lord_Howe": 2026,
		"Pacific/Apia":        2011,
		"Europe/Amsterdam":    1937,
		"America/Nuuk":        2022,
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

// Before 1970 Unix seconds are negative, so a date must floor them.
func TestSearchesBeforeTheUnixEpoch(t *testing.T) {
	s := MustParse("every 30 min from 00:00 to 23:59")
	for _, now := range []time.Time{
		time.Date(1969, 12, 31, 12, 10, 0, 0, time.UTC),
		time.Date(1900, 6, 1, 12, 10, 0, 0, time.UTC),
	} {
		if next := s.NextFrom(now); next == nil || !next.Equal(now.Add(20*time.Minute)) {
			t.Errorf("NextFrom(%v) = %v, want %v", now, next, now.Add(20*time.Minute))
		}
		if prev := s.PreviousFrom(now); prev == nil || !prev.Equal(now.Add(-10*time.Minute)) {
			t.Errorf("PreviousFrom(%v) = %v, want %v", now, prev, now.Add(-10*time.Minute))
		}
	}
}

func TestFirstNStopsAtN(t *testing.T) {
	for _, n := range []int{math.MinInt, -1, 0, 1, 3} {
		pulled := 0
		hourly := func(yield func(time.Time) bool) {
			for i := 0; ; i++ {
				pulled++
				if !yield(friday.Add(time.Duration(i) * time.Hour)) {
					return
				}
			}
		}
		got := firstN(hourly, n)
		if want := max(n, 0); len(got) != want || pulled != want {
			t.Errorf("firstN(n = %d) returned %d and pulled %d, want %d of each", n, len(got), pulled, want)
		}
	}
}

func TestNextNFromCounts(t *testing.T) {
	daily := MustParse("every day at 09:00")
	for _, n := range []int{math.MinInt, -1, 0} {
		if got := daily.NextNFrom(friday, n); len(got) != 0 {
			t.Errorf("NextNFrom(n = %d) = %v, want none", n, got)
		}
	}
	once := MustParse("on 2026-03-01 at 09:00")
	if got := once.NextNFrom(friday, math.MaxInt); len(got) != 1 {
		t.Errorf("NextNFrom(n = MaxInt) = %v, want the one occurrence", got)
	}
}

// Kiritimati (+14) and Etc/GMT+12 (-12) put the wall clock of an instant
// furthest from its UTC date, at the range ends and at the platform's limits.
func TestInstantsOutsideTheSupportedRange(t *testing.T) {
	kiritimati := mustLoadLocation(t, "Pacific/Kiritimati")
	westmost := mustLoadLocation(t, "Etc/GMT+12")
	instants := []time.Time{
		{},
		rangeStart.Add(-time.Nanosecond).In(kiritimati),
		rangeStart.Add(-time.Nanosecond).In(westmost),
		rangeEnd.In(kiritimati),
		rangeEnd.In(westmost),
		time.Unix(math.MinInt64, 0).In(kiritimati),
		time.Unix(math.MaxInt64, 999999999).In(westmost),
		time.Unix(1<<62, 0).In(kiritimati),
		time.Unix(-1<<62, 0).In(westmost),
	}
	for _, expression := range []string{"every day at 09:00", "every 30 min from 00:00 to 23:59 in Pacific/Kiritimati", "every year on dec 31 at 23:59 in Etc/GMT+12"} {
		s := MustParse(expression)
		for _, at := range instants {
			if got := s.NextFrom(at); got != nil {
				t.Errorf("%q: NextFrom(%v) = %v, want nil", expression, at, *got)
			}
			if got := s.PreviousFrom(at); got != nil {
				t.Errorf("%q: PreviousFrom(%v) = %v, want nil", expression, at, *got)
			}
			if s.Matches(at) {
				t.Errorf("%q: Matches(%v) = true, want false", expression, at)
			}
			if got := s.NextNFrom(at, 3); len(got) != 0 {
				t.Errorf("%q: NextNFrom(%v) = %v, want none", expression, at, got)
			}
			if got := slices.Collect(s.Occurrences(at)); len(got) != 0 {
				t.Errorf("%q: Occurrences(%v) = %v, want none", expression, at, got)
			}
			if got := slices.Collect(s.Between(friday, at)); len(got) != 0 {
				t.Errorf("%q: Between(friday, %v) = %v, want none", expression, at, got)
			}
			if got := slices.Collect(s.Between(at, friday)); len(got) != 0 {
				t.Errorf("%q: Between(%v, friday) = %v, want none", expression, at, got)
			}
		}
	}
}

func TestResultsAreInTheScheduleZone(t *testing.T) {
	tokyo := time.Date(2026, 2, 6, 21, 0, 0, 0, mustLoadLocation(t, "Asia/Tokyo"))
	cases := map[string]string{
		"every day at 09:00":                              "UTC",
		"every day at 09:00 in utc":                       "UTC",
		"every day at 09:00 in America/New_York":          "America/New_York",
		"every 2 hours from 00:00 to 23:59 in us/eastern": "US/Eastern",
	}
	for expression, zone := range cases {
		s := MustParse(expression)
		next, prev := s.NextFrom(tokyo), s.PreviousFrom(tokyo)
		if next == nil || prev == nil {
			t.Fatalf("%q: NextFrom = %v, PreviousFrom = %v", expression, next, prev)
		}
		results := []time.Time{*next, *prev}
		results = append(results, s.NextNFrom(tokyo, 2)...)
		results = append(results, firstN(s.Occurrences(tokyo), 2)...)
		results = append(results, slices.Collect(s.Between(tokyo, tokyo.AddDate(0, 0, 2)))...)
		if len(results) < 8 {
			t.Fatalf("%q: only %d results", expression, len(results))
		}
		for _, result := range results {
			if got := result.Location().String(); got != zone {
				t.Errorf("%q: result %v is in %s, want %s", expression, result, got, zone)
			}
		}
	}
}

func mustLoadLocation(t *testing.T, name string) *time.Location {
	t.Helper()
	loc, err := time.LoadLocation(name)
	if err != nil {
		t.Fatal(err)
	}
	return loc
}
