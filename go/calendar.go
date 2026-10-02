package hron

import (
	"slices"
	"strconv"
	"time"
)

// Dates are time.Time values at midnight UTC, so they carry no time zone.
func newDate(year int, month time.Month, day int) time.Time {
	return time.Date(year, month, day, 0, 0, 0, 0, time.UTC)
}

func validDate(year int, month time.Month, day int) (time.Time, bool) {
	if day < 1 || day > daysInMonth(year, month) {
		return time.Time{}, false
	}
	return newDate(year, month, day), true
}

func daysInMonth(year int, month time.Month) int {
	switch month {
	case time.February:
		if year%4 == 0 && (year%100 != 0 || year%400 == 0) {
			return 29
		}
		return 28
	case time.April, time.June, time.September, time.November:
		return 30
	}
	return 31
}

// dateOf counts Unix seconds, as addDays does: a search takes the date of
// every occurrence it finds.
func dateOf(t time.Time) time.Time {
	_, offset := t.Zone()
	seconds := t.Unix() + int64(offset)
	days := seconds / secondsPerDay
	if seconds%secondsPerDay < 0 {
		days--
	}
	return time.Unix(days*secondsPerDay, 0).UTC()
}

// Checked by ASCII bytes and the calendar, not left to time.Parse, whose
// documentation does not promise to reject every other spelling of a date.
func isCalendarDate(s string) bool {
	if len(s) != 10 || s[4] != '-' || s[7] != '-' {
		return false
	}
	for i := range len(s) {
		if i != 4 && i != 7 && !isDigit(s[i]) {
			return false
		}
	}
	year, _ := strconv.Atoi(s[:4])
	month, _ := strconv.Atoi(s[5:7])
	day, _ := strconv.Atoi(s[8:])
	return year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(year, time.Month(month))
}

func parseISODate(s string) (time.Time, error) {
	return time.Parse(time.DateOnly, s)
}

const secondsPerDay = 24 * 60 * 60

// addDays and daysBetween count Unix seconds, exact for dates as they are in
// UTC: AddDate is slow in a search's hot loop, and Sub saturates at about 292
// years.
func addDays(date time.Time, days int) time.Time {
	return time.Unix(date.Unix()+int64(days)*secondsPerDay, 0).UTC()
}

func daysBetween(a, b time.Time) int {
	return int((b.Unix() - a.Unix()) / secondsPerDay)
}

func monthIndex(date time.Time) int {
	return date.Year()*12 + int(date.Month()) - 1
}

func mondayOfWeek(date time.Time) time.Time {
	return addDays(date, 1-weekdayOf(date).Number())
}

func weekdayOf(date time.Time) Weekday {
	return Weekday((int(date.Weekday())+6)%7 + 1)
}

func matchesDayFilter(date time.Time, filter DayFilter) bool {
	switch filter.Kind {
	case DayFilterKindEvery:
		return true
	case DayFilterKindWeekday:
		return !isWeekend(date)
	case DayFilterKindWeekend:
		return isWeekend(date)
	default:
		return slices.Contains(filter.Days, weekdayOf(date))
	}
}

func isWeekend(date time.Time) bool {
	return date.Weekday() == time.Saturday || date.Weekday() == time.Sunday
}

func monthTargetDates(year int, month time.Month, target MonthTarget) []time.Time {
	switch target.Kind {
	case MonthTargetKindDays:
		var dates []time.Time
		for _, day := range target.ExpandDays() {
			if date, ok := validDate(year, month, day); ok {
				dates = append(dates, date)
			}
		}
		slices.SortFunc(dates, time.Time.Compare)
		return dates
	case MonthTargetKindLastDay:
		return []time.Time{lastDayOfMonth(year, month)}
	case MonthTargetKindLastWeekday:
		return []time.Time{lastWeekdayOfMonth(year, month)}
	case MonthTargetKindNearestWeekday:
		if date, ok := nearestWeekday(year, month, target.Day, target.Direction); ok {
			return []time.Time{date}
		}
	case MonthTargetKindOrdinalWeekday:
		if date, ok := ordinalWeekday(year, month, target.Ordinal, target.Weekday); ok {
			return []time.Time{date}
		}
	}
	return nil
}

func yearTargetDate(year int, target YearTarget) (time.Time, bool) {
	month := time.Month(target.Month.Number())
	switch target.Kind {
	case YearTargetKindDate, YearTargetKindDayOfMonth:
		return validDate(year, month, target.Day)
	case YearTargetKindOrdinalWeekday:
		return ordinalWeekday(year, month, target.Ordinal, target.Weekday)
	case YearTargetKindLastWeekday:
		return lastWeekdayOfMonth(year, month), true
	}
	return time.Time{}, false
}

func lastDayOfMonth(year int, month time.Month) time.Time {
	return newDate(year, month, daysInMonth(year, month))
}

func lastWeekdayOfMonth(year int, month time.Month) time.Time {
	last := lastDayOfMonth(year, month)
	switch last.Weekday() {
	case time.Saturday:
		return addDays(last, -1)
	case time.Sunday:
		return addDays(last, -2)
	}
	return last
}

func ordinalWeekday(year int, month time.Month, ordinal OrdinalPosition, weekday Weekday) (time.Time, bool) {
	if ordinal == Last {
		last := lastDayOfMonth(year, month)
		return addDays(last, -daysFrom(weekday, weekdayOf(last))), true
	}
	first := newDate(year, month, 1)
	date := addDays(first, daysFrom(weekdayOf(first), weekday)+7*(ordinal.ToN()-1))
	return date, date.Month() == month
}

func daysFrom(a, b Weekday) int {
	return (b.Number() - a.Number() + 7) % 7
}

// Without a direction the nearest weekday stays in the month, as cron's W
// does; with one it can cross into the adjacent month (spec/README.md,
// "Nearest weekday and `during`").
func nearestWeekday(year int, month time.Month, day int, toward NearestDirection) (time.Time, bool) {
	date, ok := validDate(year, month, day)
	if !ok {
		return time.Time{}, false
	}
	shift := 0
	switch date.Weekday() {
	case time.Saturday:
		switch {
		case toward == NearestNext:
			shift = 2
		case toward == NearestPrevious:
			shift = -1
		case day == 1:
			shift = 2
		default:
			shift = -1
		}
	case time.Sunday:
		switch {
		case toward == NearestNext:
			shift = 1
		case toward == NearestPrevious:
			shift = -2
		case day == daysInMonth(year, month):
			shift = -2
		default:
			shift = 1
		}
	}
	return addDays(date, shift), true
}
