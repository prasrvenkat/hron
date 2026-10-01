package hron

import "time"

const minutesPerHour = 60

// fixedTimeOn returns the instant of the wall time minute minutes after
// midnight on date, shifted forward by the gap's length when it falls in a
// spring-forward gap (spec/README.md, "DST spring-forward (gaps)").
func fixedTimeOn(date time.Time, minute int, zone *time.Location) time.Time {
	instant, _ := resolveWallClock(date, minute, zone)
	return instant
}

// slotOn returns the instant of the interval slot minute minutes after midnight
// on date, or false when that wall time falls in a spring-forward gap
// (spec/README.md, "Interval slots in a spring-forward gap").
func slotOn(date time.Time, minute int, zone *time.Location) (time.Time, bool) {
	return resolveWallClock(date, minute, zone)
}

// inSecondPass reports whether t, read in zone, is in the second pass of a
// fall-back overlap: the first pass of its wall-clock minute ended before t.
func inSecondPass(t time.Time, zone *time.Location) bool {
	first := fixedTimeOn(dateOf(t), minuteOfDay(t), zone)
	return !t.Before(first.Add(time.Minute))
}

func minuteOfDay(t time.Time) int {
	return t.Hour()*minutesPerHour + t.Minute()
}

// resolveWallClock returns the first instant whose wall-clock time in zone is
// minute minutes after midnight on date, and true; a wall time a fall-back
// repeats takes its first pass (spec/README.md, "DST fall-back (ambiguous
// times)"). If the wall time falls in a gap, it returns the instant the pre-gap
// offset gives (the time shifted forward by the gap's length) and false.
// time.Date guarantees neither choice. The offsets a day before and after the
// wall time bracket the transition that can affect it; ZoneBounds is not used
// because Go reports wrong bounds at the end of leap years beyond the zone
// file's explicit transitions. This assumes at most one offset change within a
// day of the wall time; tzdata has none closer than about four days.
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
