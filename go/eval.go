package hron

import (
	"time"
)

const maxIterations = 1000

// nextFrom computes the next occurrence after now.
func nextFrom(schedule *ScheduleData, now time.Time) *time.Time {
	loc, err := resolveTimezone(schedule.Timezone)
	if err != nil {
		return nil
	}

	var untilDate *time.Time
	if schedule.Until != nil {
		ud := resolveUntil(*schedule.Until, now)
		untilDate = &ud
	}

	hasExceptions := len(schedule.Except) > 0
	hasDuring := len(schedule.During) > 0

	current := now

	for i := 0; i < maxIterations; i++ {
		candidate := nextExpr(schedule.Expr, loc, schedule.Anchor, current)
		if candidate == nil {
			return nil
		}

		cDate := candidate.In(loc)

		// Apply until filter
		if untilDate != nil && dateOnly(cDate).After(dateOnly(*untilDate)) {
			return nil
		}

		// Apply during filter
		if hasDuring && !matchesDuring(cDate, schedule.During) {
			skipTo := nextDuringMonth(cDate, schedule.During)
			midnight := atTimeOnDate(skipTo, TimeOfDay{0, 0}, loc)
			current = midnight.Add(-time.Second)
			continue
		}

		// Apply except filter
		if hasExceptions && isExcepted(cDate, schedule.Except) {
			nextDay := cDate.AddDate(0, 0, 1)
			midnight := atTimeOnDate(nextDay, TimeOfDay{0, 0}, loc)
			current = midnight.Add(-time.Second)
			continue
		}

		return candidate
	}

	return nil
}

// nextExpr dispatches to the appropriate next function based on expression type.
func nextExpr(expr ScheduleExpr, loc *time.Location, anchor string, now time.Time) *time.Time {
	switch expr.Kind {
	case ScheduleExprKindDay:
		return nextDayRepeat(expr.Interval, expr.Days, expr.Times, loc, anchor, now)
	case ScheduleExprKindInterval:
		return nextIntervalRepeat(expr.Interval, expr.Unit, expr.FromTime, expr.ToTime, expr.DayFilter, loc, now)
	case ScheduleExprKindWeek:
		return nextWeekRepeat(expr.Interval, expr.WeekDays, expr.Times, loc, anchor, now)
	case ScheduleExprKindMonth:
		return nextMonthRepeat(expr.Interval, expr.MonthTarget, expr.Times, loc, anchor, now)
	case ScheduleExprKindOrdinal:
		return nextOrdinalRepeat(expr.Interval, expr.Ordinal, expr.OrdinalDay, expr.Times, loc, anchor, now)
	case ScheduleExprKindSingleDate:
		return nextSingleDate(expr.DateSpec, expr.Times, loc, now)
	case ScheduleExprKindYear:
		return nextYearRepeat(expr.Interval, expr.YearTarget, expr.Times, loc, anchor, now)
	default:
		return nil
	}
}

// nextNFrom computes the next n occurrences after now.
func nextNFrom(schedule *ScheduleData, now time.Time, n int) []time.Time {
	var results []time.Time
	current := now

	for len(results) < n {
		next := nextFrom(schedule, current)
		if next == nil {
			break
		}
		results = append(results, *next)
		current = next.Add(time.Minute)
	}

	return results
}

// matches checks if a datetime matches this schedule.
func matches(schedule *ScheduleData, dt time.Time) bool {
	loc, err := resolveTimezone(schedule.Timezone)
	if err != nil {
		return false
	}

	zdt := dt.In(loc)
	d := dateOnly(zdt)

	if !matchesDuring(d, schedule.During) {
		return false
	}
	if isExcepted(d, schedule.Except) {
		return false
	}

	if schedule.Until != nil {
		untilDate := resolveUntil(*schedule.Until, dt)
		if d.After(dateOnly(untilDate)) {
			return false
		}
	}

	timeMatchesWithDST := func(times []TimeOfDay) bool {
		for _, tod := range times {
			if zdt.Hour() == tod.Hour && zdt.Minute() == tod.Minute {
				return true
			}
			// DST gap check
			resolved := atTimeOnDate(d, tod, loc)
			if resolved.Unix() == dt.Unix() {
				return true
			}
		}
		return false
	}

	switch schedule.Expr.Kind {
	case ScheduleExprKindDay:
		if !matchesDayFilter(d, schedule.Expr.Days) {
			return false
		}
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		if schedule.Expr.Interval > 1 {
			anchorDate := epochDate
			if schedule.Anchor != "" {
				anchorDate, _ = parseISODate(schedule.Anchor)
			}
			dayOffset := daysBetween(dateOnly(anchorDate), d)
			return dayOffset >= 0 && dayOffset%schedule.Expr.Interval == 0
		}
		return true

	case ScheduleExprKindInterval:
		if schedule.Expr.DayFilter != nil && !matchesDayFilter(d, *schedule.Expr.DayFilter) {
			return false
		}
		fromMinutes := schedule.Expr.FromTime.TotalMinutes()
		toMinutes := schedule.Expr.ToTime.TotalMinutes()
		currentMinutes := zdt.Hour()*60 + zdt.Minute()
		if currentMinutes < fromMinutes || currentMinutes > toMinutes {
			return false
		}
		diff := currentMinutes - fromMinutes
		step := schedule.Expr.Interval
		if schedule.Expr.Unit == IntervalHours {
			step = schedule.Expr.Interval * 60
		}
		return diff >= 0 && diff%step == 0

	case ScheduleExprKindWeek:
		dow := isoWeekday(d)
		found := false
		for _, wd := range schedule.Expr.WeekDays {
			if wd.Number() == dow {
				found = true
				break
			}
		}
		if !found {
			return false
		}
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		anchorDate := epochMonday
		if schedule.Anchor != "" {
			anchorDate, _ = parseISODate(schedule.Anchor)
		}
		weeks := weeksBetween(dateOnly(anchorDate), d)
		return weeks >= 0 && weeks%schedule.Expr.Interval == 0

	case ScheduleExprKindMonth:
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		if schedule.Expr.Interval > 1 {
			anchorDate := epochDate
			if schedule.Anchor != "" {
				anchorDate, _ = parseISODate(schedule.Anchor)
			}
			monthOffset := monthsBetweenYM(dateOnly(anchorDate), d)
			if monthOffset < 0 || monthOffset%schedule.Expr.Interval != 0 {
				return false
			}
		}
		switch schedule.Expr.MonthTarget.Kind {
		case MonthTargetKindDays:
			expanded := schedule.Expr.MonthTarget.ExpandDays()
			for _, day := range expanded {
				if d.Day() == day {
					return true
				}
			}
			return false
		case MonthTargetKindLastDay:
			last := lastDayOfMonth(d.Year(), d.Month())
			return d.Day() == last.Day()
		case MonthTargetKindLastWeekday:
			lwd := lastWeekdayOfMonth(d.Year(), d.Month())
			return d.Day() == lwd.Day()
		}
		return false

	case ScheduleExprKindOrdinal:
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		if schedule.Expr.Interval > 1 {
			anchorDate := epochDate
			if schedule.Anchor != "" {
				anchorDate, _ = parseISODate(schedule.Anchor)
			}
			monthOffset := monthsBetweenYM(dateOnly(anchorDate), d)
			if monthOffset < 0 || monthOffset%schedule.Expr.Interval != 0 {
				return false
			}
		}
		var ordinalTarget time.Time
		var ok bool
		if schedule.Expr.Ordinal == Last {
			ordinalTarget = lastWeekdayInMonth(d.Year(), d.Month(), schedule.Expr.OrdinalDay)
			ok = true
		} else {
			ordinalTarget, ok = nthWeekdayOfMonth(d.Year(), d.Month(), schedule.Expr.OrdinalDay, schedule.Expr.Ordinal.ToN())
		}
		if !ok {
			return false
		}
		return d.Day() == ordinalTarget.Day()

	case ScheduleExprKindSingleDate:
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		switch schedule.Expr.DateSpec.Kind {
		case DateSpecKindISO:
			isoTarget, _ := parseISODate(schedule.Expr.DateSpec.Date)
			return d.Year() == isoTarget.Year() && d.Month() == isoTarget.Month() && d.Day() == isoTarget.Day()
		case DateSpecKindNamed:
			return int(d.Month()) == schedule.Expr.DateSpec.Month.Number() && d.Day() == schedule.Expr.DateSpec.Day
		}
		return false

	case ScheduleExprKindYear:
		if !timeMatchesWithDST(schedule.Expr.Times) {
			return false
		}
		if schedule.Expr.Interval > 1 {
			anchorYear := epochDate.Year()
			if schedule.Anchor != "" {
				anchorDate, _ := parseISODate(schedule.Anchor)
				anchorYear = anchorDate.Year()
			}
			yearOffset := d.Year() - anchorYear
			if yearOffset < 0 || yearOffset%schedule.Expr.Interval != 0 {
				return false
			}
		}
		return matchesYearTarget(schedule.Expr.YearTarget, d)
	}

	return false
}

// matchesYearTarget checks if a date matches a year target.
func matchesYearTarget(target YearTarget, d time.Time) bool {
	switch target.Kind {
	case YearTargetKindDate:
		return int(d.Month()) == target.Month.Number() && d.Day() == target.Day
	case YearTargetKindOrdinalWeekday:
		if int(d.Month()) != target.Month.Number() {
			return false
		}
		var ordinalDate time.Time
		var ok bool
		if target.Ordinal == Last {
			ordinalDate = lastWeekdayInMonth(d.Year(), d.Month(), target.Weekday)
			ok = true
		} else {
			ordinalDate, ok = nthWeekdayOfMonth(d.Year(), d.Month(), target.Weekday, target.Ordinal.ToN())
		}
		if !ok {
			return false
		}
		return d.Day() == ordinalDate.Day()
	case YearTargetKindDayOfMonth:
		return int(d.Month()) == target.Month.Number() && d.Day() == target.Day
	case YearTargetKindLastWeekday:
		if int(d.Month()) != target.Month.Number() {
			return false
		}
		lwd := lastWeekdayOfMonth(d.Year(), d.Month())
		return d.Day() == lwd.Day()
	}
	return false
}

// --- Per-variant next functions ---

func nextDayRepeat(interval int, days DayFilter, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	d := dateOnly(nowInTz)

	if interval <= 1 {
		// Original behavior for interval=1
		if matchesDayFilter(d, days) {
			candidate := earliestFutureAtTimes(d, times, loc, now)
			if candidate != nil {
				return candidate
			}
		}

		for i := 0; i < 8; i++ {
			d = d.AddDate(0, 0, 1)
			if matchesDayFilter(d, days) {
				candidate := earliestFutureAtTimes(d, times, loc, now)
				if candidate != nil {
					return candidate
				}
			}
		}

		return nil
	}

	// Interval > 1: day intervals only apply to DayFilter::Every
	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	// Find the next aligned day >= today
	offset := daysBetween(dateOnly(anchorDate), d)
	remainder := offset % interval
	if remainder < 0 {
		remainder += interval
	}
	alignedDate := d
	if remainder != 0 {
		alignedDate = d.AddDate(0, 0, interval-remainder)
	}

	for i := 0; i < 400; i++ {
		candidate := earliestFutureAtTimes(alignedDate, times, loc, now)
		if candidate != nil {
			return candidate
		}
		alignedDate = alignedDate.AddDate(0, 0, interval)
	}

	return nil
}

func nextIntervalRepeat(interval int, unit IntervalUnit, fromTime, toTime TimeOfDay, dayFilter *DayFilter, loc *time.Location, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	stepMinutes := interval
	if unit == IntervalHours {
		stepMinutes = interval * 60
	}
	fromMinutes := fromTime.TotalMinutes()
	toMinutes := toTime.TotalMinutes()

	d := dateOnly(nowInTz)

	for i := 0; i < 400; i++ {
		if dayFilter != nil && !matchesDayFilter(d, *dayFilter) {
			d = d.AddDate(0, 0, 1)
			continue
		}

		sameDay := d.Year() == nowInTz.Year() && d.Month() == nowInTz.Month() && d.Day() == nowInTz.Day()
		nowMinutes := -1
		if sameDay {
			nowMinutes = nowInTz.Hour()*60 + nowInTz.Minute()
		}

		var nextSlot int
		if nowMinutes < fromMinutes {
			nextSlot = fromMinutes
		} else {
			elapsed := nowMinutes - fromMinutes
			nextSlot = fromMinutes + (elapsed/stepMinutes+1)*stepMinutes
		}

		if nextSlot <= toMinutes {
			h := nextSlot / 60
			m := nextSlot % 60
			candidate := atTimeOnDate(d, TimeOfDay{h, m}, loc)
			if candidate.After(now) {
				return &candidate
			}
		}

		d = d.AddDate(0, 0, 1)
	}

	return nil
}

func nextWeekRepeat(interval int, days []Weekday, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	anchorDate := epochMonday
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	d := dateOnly(nowInTz)

	// Sort target DOWs for earliest-first matching
	sortedDays := make([]Weekday, len(days))
	copy(sortedDays, days)
	// Simple bubble sort
	for i := 0; i < len(sortedDays)-1; i++ {
		for j := i + 1; j < len(sortedDays); j++ {
			if sortedDays[i].Number() > sortedDays[j].Number() {
				sortedDays[i], sortedDays[j] = sortedDays[j], sortedDays[i]
			}
		}
	}

	// Find Monday of current week and Monday of anchor week
	dowOffset := (isoWeekday(d) - 1)
	currentMonday := d.AddDate(0, 0, -dowOffset)

	anchorDowOffset := (isoWeekday(anchorDate) - 1)
	anchorMonday := anchorDate.AddDate(0, 0, -anchorDowOffset)

	for i := 0; i < 54; i++ {
		weeks := weeksBetween(dateOnly(anchorMonday), currentMonday)

		// Skip weeks before anchor
		if weeks < 0 {
			skip := (-weeks + interval - 1) / interval
			currentMonday = currentMonday.AddDate(0, 0, skip*interval*7)
			continue
		}

		if weeks%interval == 0 {
			// Aligned week — try each target DOW
			for _, wd := range sortedDays {
				dayOffset := wd.Number() - 1
				targetDate := currentMonday.AddDate(0, 0, dayOffset)
				candidate := earliestFutureAtTimes(targetDate, times, loc, now)
				if candidate != nil {
					return candidate
				}
			}
		}

		// Skip to next aligned week
		remainder := weeks % interval
		skipWeeks := interval
		if remainder != 0 {
			skipWeeks = interval - remainder
		}
		currentMonday = currentMonday.AddDate(0, 0, skipWeeks*7)
	}

	return nil
}

func nextMonthRepeat(interval int, target MonthTarget, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	year := nowInTz.Year()
	month := int(nowInTz.Month())

	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}
	maxIter := 24 * interval
	if interval <= 1 {
		maxIter = 24
	}

	for i := 0; i < maxIter; i++ {
		// Check interval alignment
		if interval > 1 {
			cur := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.UTC)
			monthOffset := monthsBetweenYM(dateOnly(anchorDate), cur)
			if monthOffset < 0 || monthOffset%interval != 0 {
				month++
				if month > 12 {
					month = 1
					year++
				}
				continue
			}
		}

		var dateCandidates []time.Time

		switch target.Kind {
		case MonthTargetKindDays:
			expanded := target.ExpandDays()
			last := lastDayOfMonth(year, time.Month(month))
			for _, dayNum := range expanded {
				if dayNum <= last.Day() {
					dateCandidates = append(dateCandidates, time.Date(year, time.Month(month), dayNum, 0, 0, 0, 0, time.UTC))
				}
			}
		case MonthTargetKindLastDay:
			dateCandidates = append(dateCandidates, lastDayOfMonth(year, time.Month(month)))
		case MonthTargetKindLastWeekday:
			dateCandidates = append(dateCandidates, lastWeekdayOfMonth(year, time.Month(month)))
		}

		var best *time.Time
		for _, dc := range dateCandidates {
			candidate := earliestFutureAtTimes(dc, times, loc, now)
			if candidate != nil && (best == nil || candidate.Before(*best)) {
				best = candidate
			}
		}
		if best != nil {
			return best
		}

		month++
		if month > 12 {
			month = 1
			year++
		}
	}

	return nil
}

func nextOrdinalRepeat(interval int, ordinal OrdinalPosition, day Weekday, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	year := nowInTz.Year()
	month := int(nowInTz.Month())

	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}
	maxIter := 24 * interval
	if interval <= 1 {
		maxIter = 24
	}

	for i := 0; i < maxIter; i++ {
		// Check interval alignment
		if interval > 1 {
			cur := time.Date(year, time.Month(month), 1, 0, 0, 0, 0, time.UTC)
			monthOffset := monthsBetweenYM(dateOnly(anchorDate), cur)
			if monthOffset < 0 || monthOffset%interval != 0 {
				month++
				if month > 12 {
					month = 1
					year++
				}
				continue
			}
		}

		var ordinalDate time.Time
		var ok bool
		if ordinal == Last {
			ordinalDate = lastWeekdayInMonth(year, time.Month(month), day)
			ok = true
		} else {
			ordinalDate, ok = nthWeekdayOfMonth(year, time.Month(month), day, ordinal.ToN())
		}

		if ok {
			candidate := earliestFutureAtTimes(ordinalDate, times, loc, now)
			if candidate != nil {
				return candidate
			}
		}

		month++
		if month > 12 {
			month = 1
			year++
		}
	}

	return nil
}

func nextSingleDate(dateSpec DateSpec, times []TimeOfDay, loc *time.Location, now time.Time) *time.Time {
	nowInTz := now.In(loc)

	switch dateSpec.Kind {
	case DateSpecKindISO:
		d, _ := parseISODate(dateSpec.Date)
		return earliestFutureAtTimes(d, times, loc, now)
	case DateSpecKindNamed:
		startYear := nowInTz.Year()
		for y := 0; y < 8; y++ {
			year := startYear + y
			d := time.Date(year, time.Month(dateSpec.Month.Number()), dateSpec.Day, 0, 0, 0, 0, time.UTC)
			// Validate date is valid
			if d.Month() != time.Month(dateSpec.Month.Number()) {
				continue // Invalid date (e.g., Feb 30)
			}
			candidate := earliestFutureAtTimes(d, times, loc, now)
			if candidate != nil {
				return candidate
			}
		}
		return nil
	}

	return nil
}

func nextYearRepeat(interval int, target YearTarget, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	startYear := nowInTz.Year()
	anchorYear := epochDate.Year()
	if anchor != "" {
		anchorDate, _ := parseISODate(anchor)
		anchorYear = anchorDate.Year()
	}

	maxIter := 8 * interval
	if interval <= 1 {
		maxIter = 8
	}

	for y := 0; y < maxIter; y++ {
		year := startYear + y

		// Check interval alignment
		if interval > 1 {
			yearOffset := year - anchorYear
			if yearOffset < 0 || yearOffset%interval != 0 {
				continue
			}
		}

		var targetDate time.Time
		var valid bool

		switch target.Kind {
		case YearTargetKindDate:
			targetDate = time.Date(year, time.Month(target.Month.Number()), target.Day, 0, 0, 0, 0, time.UTC)
			// Validate the date
			valid = targetDate.Month() == time.Month(target.Month.Number()) && targetDate.Day() == target.Day
		case YearTargetKindOrdinalWeekday:
			if target.Ordinal == Last {
				targetDate = lastWeekdayInMonth(year, time.Month(target.Month.Number()), target.Weekday)
				valid = true
			} else {
				targetDate, valid = nthWeekdayOfMonth(year, time.Month(target.Month.Number()), target.Weekday, target.Ordinal.ToN())
			}
		case YearTargetKindDayOfMonth:
			targetDate = time.Date(year, time.Month(target.Month.Number()), target.Day, 0, 0, 0, 0, time.UTC)
			valid = targetDate.Month() == time.Month(target.Month.Number()) && targetDate.Day() == target.Day
		case YearTargetKindLastWeekday:
			targetDate = lastWeekdayOfMonth(year, time.Month(target.Month.Number()))
			valid = true
		}

		if valid {
			candidate := earliestFutureAtTimes(targetDate, times, loc, now)
			if candidate != nil {
				return candidate
			}
		}
	}

	return nil
}
