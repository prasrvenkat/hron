package hron

import "time"

const (
	minutesPerHour = 60
	minutesPerDay  = 24 * minutesPerHour
)

// A wall time in a spring-forward gap shifts forward by the gap's length
// (spec/README.md, "DST spring-forward (gaps)").
func fixedTimeOn(date time.Time, minute int, zone *time.Location) time.Time {
	instant, _ := resolveWallClock(date, minute, zone)
	return instant
}

// slot is an interval slot on a date: where it sits in time, and its instant
// unless a spring-forward gap skips it (spec/README.md, "Interval slots in a
// spring-forward gap"). A skipped slot sits at the instant its gap ends, so
// keys never decrease in wall-clock order and one binary search finds the
// slots on either side of an instant.
type slot struct {
	key     time.Time
	instant time.Time
	skipped bool
}

func slotOn(date time.Time, minute int, zone *time.Location) slot {
	instant, ok := resolveWallClock(date, minute, zone)
	if ok {
		return slot{key: instant, instant: instant}
	}
	// In a gap, resolveWallClock reads the wall time at the offset before it,
	// which gives an instant at or after the gap ends, at the offset after it.
	wall := date.Add(time.Duration(minute) * time.Minute)
	return slot{key: gapEnd(wall, wall.Sub(instant), offsetAt(instant, zone), zone), skipped: true}
}

// gapEnd returns the instant the spring-forward gap holding wall ends: the
// transition from offset before to offset after. Read at the later offset, wall
// is before it; read at the earlier, at or after it. Transitions fall on whole
// seconds, so a binary search over that bracket finds it.
func gapEnd(wall time.Time, before, after time.Duration, zone *time.Location) time.Time {
	lo, hi := wall.Add(-after).Unix(), wall.Add(-before).Unix()
	for hi-lo > 1 {
		mid := lo + (hi-lo)/2
		if offsetAt(time.Unix(mid, 0), zone) == after {
			hi = mid
		} else {
			lo = mid
		}
	}
	return time.Unix(hi, 0)
}

// A wall time a fall-back repeats takes its first pass (spec/README.md, "DST
// fall-back (ambiguous times)"); one in a gap takes the pre-gap offset, which
// shifts it forward by the gap's length, and returns false. time.Date
// guarantees neither choice. ZoneBounds is not used because Go reports wrong
// bounds at the end of leap years beyond the zone file's explicit transitions.
// This assumes at most one offset change within a day of the wall time; tzdata
// has none closer than about four days.
func resolveWallClock(date time.Time, minute int, zone *time.Location) (time.Time, bool) {
	wall := date.Add(time.Duration(minute) * time.Minute)
	offsetBefore := offsetAt(wall.Add(-24*time.Hour), zone)
	offsetAfter := offsetAt(wall.Add(24*time.Hour), zone)
	first, second := wall.Add(-max(offsetBefore, offsetAfter)), wall.Add(-min(offsetBefore, offsetAfter))
	for _, candidate := range []time.Time{first, second} {
		if offsetAt(candidate, zone) == wall.Sub(candidate) {
			return candidate.In(zone), true
		}
	}
	return wall.Add(-offsetBefore).In(zone), false
}

func offsetAt(t time.Time, zone *time.Location) time.Duration {
	_, offset := t.In(zone).Zone()
	return time.Duration(offset) * time.Second
}
