package hron

import (
	"time"
)

var (
	epochDate   = time.Date(1970, 1, 1, 0, 0, 0, 0, time.UTC)
	epochMonday = time.Date(1970, 1, 5, 0, 0, 0, 0, time.UTC) // Monday
)

// resolveTimezone returns UTC for an empty name so results never depend on the host zone.
func resolveTimezone(tzName string) (*time.Location, error) {
	if tzName != "" {
		return time.LoadLocation(tzName)
	}
	return time.UTC, nil
}

func atTimeOnDate(d time.Time, tod TimeOfDay, loc *time.Location) time.Time {
	t := time.Date(d.Year(), d.Month(), d.Day(), tod.Hour, tod.Minute, 0, 0, loc)

	// The spec requires a gap time to shift forward by the gap length and an
	// ambiguous time to take its first occurrence (spec/README.md, "DST
	// spring-forward (gaps)" and "DST fall-back (ambiguous times)"). time.Date
	// guarantees neither, so a gap time it moved backward is corrected here.
	if t.Hour() != tod.Hour || t.Minute() != tod.Minute {
		requestedMinutes := tod.Hour*60 + tod.Minute
		gotMinutes := t.Hour()*60 + t.Minute()
		gapMinutes := requestedMinutes - gotMinutes

		if gapMinutes > 0 {
			return t.Add(time.Duration(gapMinutes) * time.Minute)
		}
	}

	return t
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

func weeksBetween(a, b time.Time) int {
	days := int(b.Sub(a).Hours() / 24)
	return days / 7
}

func daysBetween(a, b time.Time) int {
	return int(b.Sub(a).Hours() / 24)
}

// monthsBetweenYM returns the number of months between two dates (based on year/month only).
func monthsBetweenYM(a, b time.Time) int {
	return (b.Year()*12 + int(b.Month())) - (a.Year()*12 + int(a.Month()))
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

func resolveUntil(until UntilSpec, now time.Time) time.Time {
	switch until.Kind {
	case UntilSpecKindISO:
		d, _ := time.Parse("2006-01-02", until.Date)
		return d
	case UntilSpecKindNamed:
		year := now.Year()
		for y := year; y <= year+1; y++ {
			d := time.Date(y, time.Month(until.Month.Number()), until.Day, 0, 0, 0, 0, time.UTC)
			if !d.Before(time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)) {
				return d
			}
		}
		return time.Date(year+1, time.Month(until.Month.Number()), until.Day, 0, 0, 0, 0, time.UTC)
	default:
		return time.Time{}
	}
}

// earliestFutureAtTimes finds the earliest time in the list that is strictly after now.
func earliestFutureAtTimes(d time.Time, times []TimeOfDay, loc *time.Location, now time.Time) *time.Time {
	var best *time.Time
	for _, tod := range times {
		candidate := atTimeOnDate(d, tod, loc)
		if candidate.After(now) {
			if best == nil || candidate.Before(*best) {
				c := candidate
				best = &c
			}
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
