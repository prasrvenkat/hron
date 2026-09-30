package hron

import (
	"fmt"
	"time"
)

var (
	epochDate   = time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC)
	epochMonday = time.Date(1970, 1, 5, 0, 0, 0, 0, time.UTC) // Monday
)

// resolveTimezone returns the location and canonical name for tzName, and UTC
// for an empty name so results never depend on the host zone.
func resolveTimezone(tzName string) (*time.Location, string, error) {
	if tzName == "" {
		return time.UTC, "", nil
	}
	canonical, ok := canonicalTimezone(tzName)
	if !ok {
		return nil, "", &HronError{Kind: ErrorKindParse, Message: unknownTimezoneMessage(tzName)}
	}
	loc, err := time.LoadLocation(canonical)
	if err != nil {
		return nil, "", &HronError{Kind: ErrorKindParse, Message: unknownTimezoneMessage(tzName)}
	}
	return loc, canonical, nil
}

func unknownTimezoneMessage(name string) string {
	return fmt.Sprintf("unknown timezone %q: use UTC or an IANA Area/Location name such as America/New_York", name)
}

// atTimeOnDate resolves a fixed time on date d. A time skipped by a
// spring-forward gap shifts forward by the gap length, and a time repeated by
// a fall-back overlap takes its first occurrence (spec/README.md, "DST
// spring-forward (gaps)" and "DST fall-back (ambiguous times)").
func atTimeOnDate(d time.Time, tod TimeOfDay, loc *time.Location) time.Time {
	t, _ := resolveWallClock(d, tod, loc)
	return t
}

// resolveWallClock returns the first instant whose wall-clock time in loc is
// tod on date d, and true. If that wall time falls in a gap, it returns the
// instant the pre-gap offset gives (the time shifted forward by the gap
// length) and false. time.Date guarantees neither choice. The offsets a day
// before and after the wall time bracket the transition that can affect it;
// ZoneBounds is not used because Go reports wrong bounds at the end of leap
// years beyond the zone file's explicit transitions. This assumes at most one
// offset change within a day of the wall time; tzdata has none closer than
// about four days.
func resolveWallClock(d time.Time, tod TimeOfDay, loc *time.Location) (time.Time, bool) {
	wall := time.Date(d.Year(), d.Month(), d.Day(), tod.Hour, tod.Minute, 0, 0, time.UTC)
	offsetBefore := offsetAt(wall.Add(-24*time.Hour), loc)
	offsetAfter := offsetAt(wall.Add(24*time.Hour), loc)
	first, second := wall.Add(-max(offsetBefore, offsetAfter)), wall.Add(-min(offsetBefore, offsetAfter))
	for _, candidate := range []time.Time{first, second} {
		if offsetAt(candidate, loc) == wall.Sub(candidate) {
			return candidate.In(loc), true
		}
	}
	return wall.Add(-offsetBefore).In(loc), false
}

func offsetAt(t time.Time, loc *time.Location) time.Duration {
	_, offset := t.In(loc).Zone()
	return time.Duration(offset) * time.Second
}

func matchesDayFilter(d time.Time, f DayFilter) bool {
	dow := d.Weekday()               // Sunday=0, Monday=1, ..., Saturday=6
	isoWeekday := (int(dow)+6)%7 + 1 // Convert to ISO: Monday=1, Sunday=7

	switch f.Kind {
	case DayFilterKindEvery:
		return true
	case DayFilterKindWeekday:
		return isoWeekday >= 1 && isoWeekday <= 5
	case DayFilterKindWeekend:
		return isoWeekday == 6 || isoWeekday == 7
	case DayFilterKindDays:
		for _, wd := range f.Days {
			if wd.Number() == isoWeekday {
				return true
			}
		}
		return false
	default:
		return false
	}
}

func lastDayOfMonth(year int, month time.Month) time.Time {
	firstOfNext := time.Date(year, month+1, 1, 0, 0, 0, 0, time.UTC)
	return firstOfNext.AddDate(0, 0, -1)
}

// lastWeekdayOfMonth returns the last weekday (Mon-Fri) of the given month.
func lastWeekdayOfMonth(year int, month time.Month) time.Time {
	d := lastDayOfMonth(year, month)
	for {
		dow := d.Weekday()
		if dow != time.Saturday && dow != time.Sunday {
			return d
		}
		d = d.AddDate(0, 0, -1)
	}
}

// nthWeekdayOfMonth returns false if the month has no nth occurrence of weekday.
func nthWeekdayOfMonth(year int, month time.Month, weekday Weekday, n int) (time.Time, bool) {
	targetDOW := time.Weekday((weekday.Number() % 7))

	d := time.Date(year, month, 1, 0, 0, 0, 0, time.UTC)

	for d.Weekday() != targetDOW {
		d = d.AddDate(0, 0, 1)
	}

	d = d.AddDate(0, 0, (n-1)*7)

	if d.Month() != month {
		return time.Time{}, false
	}

	return d, true
}

// lastWeekdayInMonth returns the last occurrence of a specific weekday in a month.
func lastWeekdayInMonth(year int, month time.Month, weekday Weekday) time.Time {
	targetDOW := time.Weekday((weekday.Number() % 7))
	d := lastDayOfMonth(year, month)
	for d.Weekday() != targetDOW {
		d = d.AddDate(0, 0, -1)
	}
	return d
}

// weeksBetween expects two Mondays at midnight UTC.
func weeksBetween(a, b time.Time) int {
	return daysBetween(a, b) / 7
}

// daysBetween expects two dates at midnight UTC. It avoids time.Duration,
// which saturates at about 292 years.
func daysBetween(a, b time.Time) int {
	return int((b.Unix() - a.Unix()) / 86400)
}

// monthIndex counts months from year 0, so month arithmetic is integer arithmetic.
func monthIndex(t time.Time) int {
	return t.Year()*12 + int(t.Month()) - 1
}

// floorMod returns a mod n in [0, n), so offsets before an anchor align by
// floor division rather than truncation.
func floorMod(a, n int) int {
	m := a % n
	if m < 0 {
		m += n
	}
	return m
}

// maxSearchYears covers the whole supported range, which caps any horizon.
const maxSearchYears = 10000

// horizonUnits returns how many interval units a search spans. The Gregorian
// calendar repeats every 400 years (units of the interval's kind), so a
// schedule repeats after lcm(units, interval) units (spec/README.md, "Search
// horizon"); no search needs to span more than maxSearchYears.
func horizonUnits(interval, units int) int {
	n := max(interval, 1)
	maxUnits := maxSearchYears / 400 * units
	if repeats := units / gcd(units, n); repeats <= maxUnits/n {
		return repeats * n
	}
	return maxUnits
}

// searchSteps returns how many interval steps cover the search horizon.
func searchSteps(interval, units int) int {
	return ceilDiv(horizonUnits(interval, units), max(interval, 1))
}

func floorDiv(a, b int) int {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func ceilDiv(a, b int) int {
	q := a / b
	if a%b != 0 {
		q++
	}
	return q
}

func gcd(a, b int) int {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

// monthTargetDates returns the dates target names in a month, skipping days the month lacks.
func monthTargetDates(year int, month time.Month, target MonthTarget) []time.Time {
	switch target.Kind {
	case MonthTargetKindDays:
		var dates []time.Time
		last := lastDayOfMonth(year, month).Day()
		for _, day := range target.ExpandDays() {
			if day <= last {
				dates = append(dates, time.Date(year, month, day, 0, 0, 0, 0, time.UTC))
			}
		}
		return dates
	case MonthTargetKindLastDay:
		return []time.Time{lastDayOfMonth(year, month)}
	case MonthTargetKindLastWeekday:
		return []time.Time{lastWeekdayOfMonth(year, month)}
	case MonthTargetKindNearestWeekday:
		if d, ok := nearestWeekday(year, month, target.Day, target.Direction); ok {
			return []time.Time{d}
		}
	case MonthTargetKindOrdinalWeekday:
		if target.Ordinal == Last {
			return []time.Time{lastWeekdayInMonth(year, month, target.Weekday)}
		}
		if d, ok := nthWeekdayOfMonth(year, month, target.Weekday, target.Ordinal.ToN()); ok {
			return []time.Time{d}
		}
	}
	return nil
}

// yearTargetDate returns false if the year has no such date (Feb 29, a fifth weekday).
func yearTargetDate(year int, target YearTarget) (time.Time, bool) {
	month := time.Month(target.Month.Number())
	switch target.Kind {
	case YearTargetKindDate, YearTargetKindDayOfMonth:
		d := time.Date(year, month, target.Day, 0, 0, 0, 0, time.UTC)
		return d, d.Month() == month
	case YearTargetKindOrdinalWeekday:
		if target.Ordinal == Last {
			return lastWeekdayInMonth(year, month, target.Weekday), true
		}
		return nthWeekdayOfMonth(year, month, target.Weekday, target.Ordinal.ToN())
	case YearTargetKindLastWeekday:
		return lastWeekdayOfMonth(year, month), true
	}
	return time.Time{}, false
}

// namedDate returns false if the year has no such date (Feb 29).
func namedDate(year int, dateSpec DateSpec) (time.Time, bool) {
	month := time.Month(dateSpec.Month.Number())
	d := time.Date(year, month, dateSpec.Day, 0, 0, 0, 0, time.UTC)
	return d, d.Month() == month
}

func isExcepted(d time.Time, exceptions []ExceptionSpec) bool {
	for _, exc := range exceptions {
		switch exc.Kind {
		case ExceptionSpecKindNamed:
			if int(d.Month()) == exc.Month.Number() && d.Day() == exc.Day {
				return true
			}
		case ExceptionSpecKindISO:
			excDate, err := time.Parse("2006-01-02", exc.Date)
			if err == nil && d.Year() == excDate.Year() && d.Month() == excDate.Month() && d.Day() == excDate.Day() {
				return true
			}
		}
	}
	return false
}

func matchesDuring(d time.Time, during []MonthName) bool {
	if len(during) == 0 {
		return true
	}
	for _, m := range during {
		if int(d.Month()) == m.Number() {
			return true
		}
	}
	return false
}

// nextDuringMonth returns the first day of the next allowed month.
func nextDuringMonth(d time.Time, during []MonthName) time.Time {
	currentMonth := int(d.Month())

	months := make([]int, len(during))
	for i, m := range during {
		months[i] = m.Number()
	}
	for i := 0; i < len(months)-1; i++ {
		for j := i + 1; j < len(months); j++ {
			if months[i] > months[j] {
				months[i], months[j] = months[j], months[i]
			}
		}
	}

	for _, m := range months {
		if m > currentMonth {
			return time.Date(d.Year(), time.Month(m), 1, 0, 0, 0, 0, time.UTC)
		}
	}
	return time.Date(d.Year()+1, time.Month(months[0]), 1, 0, 0, 0, 0, time.UTC)
}

// resolveUntil returns the last date a schedule may fire on. A named until is
// the first such date on or after the starting date (spec/README.md, "Named
// until"); consecutive Feb 29s can be eight years apart. Parse rejects the
// inputs that find no such date (no starting, Feb 30), which end the schedule.
func resolveUntil(until UntilSpec, anchor string) time.Time {
	if until.Kind == UntilSpecKindISO {
		d, _ := parseISODate(until.Date)
		return d
	}
	start, _ := parseISODate(anchor)
	for year := start.Year(); year <= start.Year()+8; year++ {
		if d, ok := namedDate(year, NewNamedDate(until.Month, until.Day)); ok && !d.Before(start) {
			return d
		}
	}
	return time.Time{}
}

// earliestFutureAtTimes finds the earliest of times on date d that is strictly
// after now, if d is not before startDate.
func earliestFutureAtTimes(d time.Time, times []TimeOfDay, loc *time.Location, now, startDate time.Time) *occurrence {
	if d.Before(startDate) {
		return nil
	}
	var best *occurrence
	for _, tod := range times {
		at := atTimeOnDate(d, tod, loc)
		if at.After(now) && (best == nil || at.Before(best.at)) {
			best = &occurrence{at, d}
		}
	}
	return best
}

func parseISODate(s string) (time.Time, error) {
	return time.Parse("2006-01-02", s)
}

// dateOnly returns a date with time set to midnight UTC.
func dateOnly(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
}

// isoWeekday returns the ISO weekday (Monday=1, Sunday=7).
func isoWeekday(t time.Time) int {
	dow := t.Weekday()
	return (int(dow)+6)%7 + 1
}

// nearestWeekday returns false if targetDay does not exist in the month.
// NearestNone never leaves the month (cron W); a direction may cross it.
func nearestWeekday(year int, month time.Month, targetDay int, direction NearestDirection) (time.Time, bool) {
	last := lastDayOfMonth(year, month)
	lastDay := last.Day()

	if targetDay > lastDay {
		return time.Time{}, false
	}

	date := time.Date(year, month, targetDay, 0, 0, 0, 0, time.UTC)
	dow := date.Weekday()

	if dow != time.Saturday && dow != time.Sunday {
		return date, true
	}

	switch dow {
	case time.Saturday:
		switch direction {
		case NearestNone:
			// Standard: prefer Friday, but if at month start, use Monday
			if targetDay == 1 {
				return date.AddDate(0, 0, 2), true
			}
			return date.AddDate(0, 0, -1), true
		case NearestNext:
			return date.AddDate(0, 0, 2), true
		case NearestPrevious:
			return date.AddDate(0, 0, -1), true
		}

	case time.Sunday:
		switch direction {
		case NearestNone:
			// Standard: prefer Monday, but if at month end, use Friday
			if targetDay >= lastDay {
				return date.AddDate(0, 0, -2), true
			}
			return date.AddDate(0, 0, 1), true
		case NearestNext:
			return date.AddDate(0, 0, 1), true
		case NearestPrevious:
			return date.AddDate(0, 0, -2), true
		}
	}

	return date, true
}
