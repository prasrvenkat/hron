package hron

import (
	"iter"
	"time"
)

// =============================================================================
// Iteration Safety Limits
// =============================================================================
// maxIterations (1000): Maximum iterations for nextFrom/previousFrom loops.
// Prevents infinite loops when searching for valid occurrences.
//
// Expression-specific limits:
// - Day repeat: 8 days (covers one week + margin)
// - Week repeat: 54 weeks (covers one year + margin)
// - Month repeat: 24 * interval months (covers 2 years scaled by interval)
// - Year repeat: 8 * interval years (covers reasonable future horizon)
//
// These limits are generous safety bounds. In practice, valid schedules
// find occurrences within the first few iterations.
// =============================================================================

// =============================================================================
// DST (Daylight Saving Time) Handling
// =============================================================================
// When resolving a wall-clock time to an instant:
//
// 1. DST Gap (Spring Forward):
//    - Time doesn't exist (e.g., 2:30 AM during spring forward)
//    - Solution: Push forward to the next valid time after the gap
//    - Example: 2:30 AM -> 3:00 AM (or 3:30 AM depending on gap size)
//
// 2. DST Fold (Fall Back):
//    - Time is ambiguous (e.g., 1:30 AM occurs twice)
//    - Solution: Use first occurrence (fold=0 / pre-transition time)
//    - This matches user expectation for scheduling
//
// All implementations use the same algorithm for cross-language consistency.
// =============================================================================

// =============================================================================
// Interval Alignment (Anchor Date)
// =============================================================================
// For schedules with interval > 1 (e.g., "every 3 days"), we need to
// determine which dates are valid based on alignment with an anchor.
//
// Formula: (date_offset - anchor_offset) mod interval == 0
//
// Where:
//   - date_offset: days/weeks/months from epoch to candidate date
//   - anchor_offset: days/weeks/months from epoch to anchor date
//   - interval: the repeat interval (e.g., 3 for "every 3 days")
//
// Default anchor: Epoch (1970-01-01)
// Custom anchor: Set via "starting YYYY-MM-DD" clause
//
// For week repeats, we use epoch Monday (1970-01-05) as the reference
// point to align week boundaries correctly.
// =============================================================================

const maxIterations = 1000

// nextFrom computes the next occurrence after now.
func nextFrom(schedule *ScheduleData, loc *time.Location, now time.Time) *time.Time {
	var untilDate *time.Time
	if schedule.Until != nil {
		ud := resolveUntil(*schedule.Until, now)
		untilDate = &ud
	}

	hasExceptions := len(schedule.Except) > 0
	hasDuring := len(schedule.During) > 0

	// Check if expression is NearestWeekday with direction (can cross month boundaries)
	handlesDuringInternally := schedule.Expr.Kind == ScheduleExprKindMonth &&
		schedule.Expr.MonthTarget.Kind == MonthTargetKindNearestWeekday &&
		schedule.Expr.MonthTarget.Direction != NearestNone

	current := now

	for i := 0; i < maxIterations; i++ {
		var candidate *time.Time
		if handlesDuringInternally {
			candidate = nextExprWithDuring(schedule.Expr, loc, schedule.Anchor, current, schedule.During)
		} else {
			candidate = nextExpr(schedule.Expr, loc, schedule.Anchor, current)
		}
		if candidate == nil {
			return nil
		}

		cDate := candidate.In(loc)

		// Apply until filter
		if untilDate != nil && dateOnly(cDate).After(dateOnly(*untilDate)) {
			return nil
		}

		// Apply during filter
		// Skip this check for expressions that handle during internally (NearestWeekday with direction)
		if hasDuring && !handlesDuringInternally && !matchesDuring(cDate, schedule.During) {
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
	return nextExprWithDuring(expr, loc, anchor, now, nil)
}

// nextExprWithDuring dispatches to the appropriate next function, passing during filter for special handling.
func nextExprWithDuring(expr ScheduleExpr, loc *time.Location, anchor string, now time.Time, during []MonthName) *time.Time {
	switch expr.Kind {
	case ScheduleExprKindDay:
		return nextDayRepeat(expr.Interval, expr.Days, expr.Times, loc, anchor, now)
	case ScheduleExprKindInterval:
		return nextIntervalRepeat(expr.Interval, expr.Unit, expr.FromTime, expr.ToTime, expr.DayFilter, loc, now)
	case ScheduleExprKindWeek:
		return nextWeekRepeat(expr.Interval, expr.WeekDays, expr.Times, loc, anchor, now)
	case ScheduleExprKindMonth:
		return nextMonthRepeatWithDuring(expr.Interval, expr.MonthTarget, expr.Times, loc, anchor, now, during)
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
func nextNFrom(schedule *ScheduleData, loc *time.Location, now time.Time, n int) []time.Time {
	var results []time.Time
	current := now

	for len(results) < n {
		next := nextFrom(schedule, loc, current)
		if next == nil {
			break
		}
		results = append(results, *next)
		current = next.Add(time.Minute)
	}

	return results
}

// matches checks if a datetime matches this schedule.
func matches(schedule *ScheduleData, loc *time.Location, dt time.Time) bool {
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
		case MonthTargetKindNearestWeekday:
			nwd, ok := nearestWeekday(d.Year(), d.Month(), schedule.Expr.MonthTarget.Day, schedule.Expr.MonthTarget.Direction)
			if !ok {
				return false
			}
			return d.Year() == nwd.Year() && d.Month() == nwd.Month() && d.Day() == nwd.Day()
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

		// Skip weeks before anchor - anchor Monday is always the first aligned week
		if weeks < 0 {
			currentMonday = anchorMonday
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
	return nextMonthRepeatWithDuring(interval, target, times, loc, anchor, now, nil)
}

func nextMonthRepeatWithDuring(interval int, target MonthTarget, times []TimeOfDay, loc *time.Location, anchor string, now time.Time, during []MonthName) *time.Time {
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

	// For NearestWeekday with direction, we need to apply the during filter here
	// because the result can cross month boundaries
	applyDuringFilter := len(during) > 0 &&
		target.Kind == MonthTargetKindNearestWeekday &&
		target.Direction != NearestNone

	for i := 0; i < maxIter; i++ {
		// Check during filter for NearestWeekday with direction
		if applyDuringFilter {
			found := false
			for _, mn := range during {
				if mn.Number() == month {
					found = true
					break
				}
			}
			if !found {
				month++
				if month > 12 {
					month = 1
					year++
				}
				continue
			}
		}

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
		case MonthTargetKindNearestWeekday:
			if nwd, ok := nearestWeekday(year, time.Month(month), target.Day, target.Direction); ok {
				dateCandidates = append(dateCandidates, nwd)
			}
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

// --- Iterator functions ---

// Occurrences returns a lazy iterator of occurrences starting after `from`.
// The iterator is unbounded for repeating schedules (will iterate forever unless limited),
// but respects the `until` clause if specified in the schedule.
func Occurrences(schedule *Schedule, from time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		current := from
		for {
			next := schedule.NextFrom(current)
			if next == nil {
				return
			}
			// Advance cursor by 1 minute to avoid returning same occurrence
			current = next.Add(time.Minute)
			if !yield(*next) {
				return
			}
		}
	}
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
// The iterator yields occurrences strictly after `from` and up to and including `to`.
func Between(schedule *Schedule, from, to time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		for dt := range Occurrences(schedule, from) {
			if dt.After(to) {
				return
			}
			if !yield(dt) {
				return
			}
		}
	}
}

// --- Previous From ---

// previousFrom computes the most recent occurrence strictly before now.
func previousFrom(schedule *ScheduleData, loc *time.Location, now time.Time) *time.Time {
	hasExceptions := len(schedule.Except) > 0
	hasDuring := len(schedule.During) > 0

	current := now

	for i := 0; i < maxIterations; i++ {
		candidate := prevExpr(schedule.Expr, loc, schedule.Anchor, current)
		if candidate == nil {
			return nil
		}

		cDate := candidate.In(loc)

		// Check starting anchor - if before anchor, no previous occurrence
		if schedule.Anchor != "" {
			anchorDate, _ := parseISODate(schedule.Anchor)
			if dateOnly(cDate).Before(dateOnly(anchorDate)) {
				return nil
			}
		}

		// Apply until filter for previousFrom:
		// If candidate is after until, search earlier
		if schedule.Until != nil {
			untilDate := resolveUntil(*schedule.Until, now)
			if dateOnly(cDate).After(dateOnly(untilDate)) {
				endOfDay := atTimeOnDate(dateOnly(untilDate), TimeOfDay{23, 59}, loc)
				current = endOfDay.Add(time.Second)
				continue
			}
		}

		// Apply during filter
		if hasDuring && !matchesDuring(cDate, schedule.During) {
			skipTo := prevDuringMonth(cDate, schedule.During)
			current = atTimeOnDate(skipTo, TimeOfDay{23, 59}, loc).Add(time.Second)
			continue
		}

		// Apply except filter
		if hasExceptions && isExcepted(cDate, schedule.Except) {
			prevDay := dateOnly(cDate).AddDate(0, 0, -1)
			current = atTimeOnDate(prevDay, TimeOfDay{23, 59}, loc).Add(time.Second)
			continue
		}

		return candidate
	}

	return nil
}

// prevExpr dispatches to the appropriate prev function based on expression type.
func prevExpr(expr ScheduleExpr, loc *time.Location, anchor string, now time.Time) *time.Time {
	switch expr.Kind {
	case ScheduleExprKindDay:
		return prevDayRepeat(expr.Interval, expr.Days, expr.Times, loc, anchor, now)
	case ScheduleExprKindInterval:
		return prevIntervalRepeat(expr.Interval, expr.Unit, expr.FromTime, expr.ToTime, expr.DayFilter, loc, now)
	case ScheduleExprKindWeek:
		return prevWeekRepeat(expr.Interval, expr.WeekDays, expr.Times, loc, anchor, now)
	case ScheduleExprKindMonth:
		return prevMonthRepeat(expr.Interval, expr.MonthTarget, expr.Times, loc, anchor, now)
	case ScheduleExprKindOrdinal:
		return prevOrdinalRepeat(expr.Interval, expr.Ordinal, expr.OrdinalDay, expr.Times, loc, anchor, now)
	case ScheduleExprKindSingleDate:
		return prevSingleDate(expr.DateSpec, expr.Times, loc, now)
	case ScheduleExprKindYear:
		return prevYearRepeat(expr.Interval, expr.YearTarget, expr.Times, loc, anchor, now)
	default:
		return nil
	}
}

// prevDuringMonth finds the last day of the previous month in the during list.
func prevDuringMonth(d time.Time, during []MonthName) time.Time {
	duringSet := make(map[int]bool)
	for _, mn := range during {
		duringSet[mn.Number()] = true
	}

	year := d.Year()
	month := int(d.Month()) - 1
	if month < 1 {
		month = 12
		year--
	}

	for i := 0; i < 13; i++ {
		if duringSet[month] {
			return lastDayOfMonth(year, time.Month(month))
		}
		month--
		if month < 1 {
			month = 12
			year--
		}
	}

	return d.AddDate(0, 0, -1)
}

// latestPastAtTimes finds the latest time on date d that is strictly before now.
func latestPastAtTimes(d time.Time, times []TimeOfDay, loc *time.Location, now time.Time) *time.Time {
	// Sort times in descending order
	sortedTimes := make([]TimeOfDay, len(times))
	copy(sortedTimes, times)
	for i := 0; i < len(sortedTimes)-1; i++ {
		for j := i + 1; j < len(sortedTimes); j++ {
			if sortedTimes[i].TotalMinutes() < sortedTimes[j].TotalMinutes() {
				sortedTimes[i], sortedTimes[j] = sortedTimes[j], sortedTimes[i]
			}
		}
	}

	for _, tod := range sortedTimes {
		candidate := atTimeOnDate(d, tod, loc)
		if candidate.Before(now) {
			return &candidate
		}
	}
	return nil
}

// latestAtTimes finds the latest time on date d.
func latestAtTimes(d time.Time, times []TimeOfDay, loc *time.Location) *time.Time {
	if len(times) == 0 {
		return nil
	}

	// Find the latest time
	latest := times[0]
	for _, tod := range times[1:] {
		if tod.TotalMinutes() > latest.TotalMinutes() {
			latest = tod
		}
	}

	result := atTimeOnDate(d, latest, loc)
	return &result
}

func prevDayRepeat(interval int, days DayFilter, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	d := dateOnly(nowInTz)

	if interval <= 1 {
		// Check today for times that have passed
		if matchesDayFilter(d, days) {
			candidate := latestPastAtTimes(d, times, loc, now)
			if candidate != nil {
				return candidate
			}
		}

		// Go back day by day
		for i := 0; i < 8; i++ {
			d = d.AddDate(0, 0, -1)
			if matchesDayFilter(d, days) {
				candidate := latestAtTimes(d, times, loc)
				if candidate != nil {
					return candidate
				}
			}
		}

		return nil
	}

	// Interval > 1
	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	offset := daysBetween(dateOnly(anchorDate), d)
	remainder := offset % interval
	if remainder < 0 {
		remainder += interval
	}
	alignedDate := d
	if remainder != 0 {
		alignedDate = d.AddDate(0, 0, -remainder)
	}

	for i := 0; i < 2; i++ {
		candidate := latestPastAtTimes(alignedDate, times, loc, now)
		if candidate != nil {
			return candidate
		}
		latest := latestAtTimes(alignedDate, times, loc)
		if latest != nil && latest.Before(now) {
			return latest
		}
		alignedDate = alignedDate.AddDate(0, 0, -interval)
	}

	return nil
}

func prevIntervalRepeat(interval int, unit IntervalUnit, fromTime, toTime TimeOfDay, dayFilter *DayFilter, loc *time.Location, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	d := dateOnly(nowInTz)

	stepMinutes := interval
	if unit == IntervalHours {
		stepMinutes = interval * 60
	}
	fromMinutes := fromTime.TotalMinutes()
	toMinutes := toTime.TotalMinutes()

	for dayOffset := 0; dayOffset < 8; dayOffset++ {
		if dayFilter != nil && !matchesDayFilter(d, *dayFilter) {
			d = d.AddDate(0, 0, -1)
			continue
		}

		nowMinutes := toMinutes + 1
		if dayOffset == 0 {
			nowMinutes = nowInTz.Hour()*60 + nowInTz.Minute()
		}
		searchUntil := nowMinutes
		if searchUntil > toMinutes {
			searchUntil = toMinutes
		}

		if searchUntil >= fromMinutes {
			slotsInRange := (searchUntil - fromMinutes) / stepMinutes
			lastSlotMinutes := fromMinutes + slotsInRange*stepMinutes

			if dayOffset == 0 && lastSlotMinutes >= nowMinutes {
				lastSlotMinutes -= stepMinutes
			}

			if lastSlotMinutes >= fromMinutes {
				h := lastSlotMinutes / 60
				m := lastSlotMinutes % 60
				result := atTimeOnDate(d, TimeOfDay{h, m}, loc)
				return &result
			}
		}

		d = d.AddDate(0, 0, -1)
	}

	return nil
}

func prevWeekRepeat(interval int, days []Weekday, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	d := dateOnly(nowInTz)
	anchorDate := epochMonday
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	// Sort target DOWs in reverse order for latest-first matching
	sortedDays := make([]Weekday, len(days))
	copy(sortedDays, days)
	for i := 0; i < len(sortedDays)-1; i++ {
		for j := i + 1; j < len(sortedDays); j++ {
			if sortedDays[i].Number() < sortedDays[j].Number() {
				sortedDays[i], sortedDays[j] = sortedDays[j], sortedDays[i]
			}
		}
	}

	// Find Monday of current week and Monday of anchor week
	dowOffset := isoWeekday(d) - 1
	currentMonday := d.AddDate(0, 0, -dowOffset)

	anchorDowOffset := isoWeekday(anchorDate) - 1
	anchorMonday := anchorDate.AddDate(0, 0, -anchorDowOffset)

	for i := 0; i < 54; i++ {
		weeks := weeksBetween(dateOnly(anchorMonday), currentMonday)

		if weeks < 0 {
			return nil
		}

		if weeks%interval == 0 {
			// Aligned week — try each target DOW in reverse order
			for _, wd := range sortedDays {
				dayOff := wd.Number() - 1
				targetDate := currentMonday.AddDate(0, 0, dayOff)
				if targetDate.After(d) {
					continue
				}
				if targetDate.Year() == d.Year() && targetDate.Month() == d.Month() && targetDate.Day() == d.Day() {
					candidate := latestPastAtTimes(targetDate, times, loc, now)
					if candidate != nil {
						return candidate
					}
				} else {
					candidate := latestAtTimes(targetDate, times, loc)
					if candidate != nil {
						return candidate
					}
				}
			}
		}

		// Go back to previous aligned week
		remainder := weeks % interval
		skipWeeks := interval
		if remainder != 0 {
			skipWeeks = remainder
		}
		currentMonday = currentMonday.AddDate(0, 0, -skipWeeks*7)
	}

	return nil
}

func prevMonthRepeat(interval int, target MonthTarget, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	startDate := dateOnly(nowInTz)
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
				month--
				if month < 1 {
					month = 12
					year--
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
		case MonthTargetKindNearestWeekday:
			if nwd, ok := nearestWeekday(year, time.Month(month), target.Day, target.Direction); ok {
				dateCandidates = append(dateCandidates, nwd)
			}
		}

		// Sort in reverse order for latest first
		for k := 0; k < len(dateCandidates)-1; k++ {
			for j := k + 1; j < len(dateCandidates); j++ {
				if dateCandidates[k].Before(dateCandidates[j]) {
					dateCandidates[k], dateCandidates[j] = dateCandidates[j], dateCandidates[k]
				}
			}
		}

		for _, dc := range dateCandidates {
			if dc.After(startDate) {
				continue
			}
			if dc.Year() == startDate.Year() && dc.Month() == startDate.Month() && dc.Day() == startDate.Day() {
				candidate := latestPastAtTimes(dc, times, loc, now)
				if candidate != nil {
					return candidate
				}
			} else {
				candidate := latestAtTimes(dc, times, loc)
				if candidate != nil {
					return candidate
				}
			}
		}

		month--
		if month < 1 {
			month = 12
			year--
		}
	}

	return nil
}

func prevOrdinalRepeat(interval int, ordinal OrdinalPosition, day Weekday, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	startDate := dateOnly(nowInTz)
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
				month--
				if month < 1 {
					month = 12
					year--
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
			if ordinalDate.After(startDate) {
				// Future, skip
			} else if ordinalDate.Year() == startDate.Year() && ordinalDate.Month() == startDate.Month() && ordinalDate.Day() == startDate.Day() {
				candidate := latestPastAtTimes(ordinalDate, times, loc, now)
				if candidate != nil {
					return candidate
				}
			} else {
				candidate := latestAtTimes(ordinalDate, times, loc)
				if candidate != nil {
					return candidate
				}
			}
		}

		month--
		if month < 1 {
			month = 12
			year--
		}
	}

	return nil
}

func prevSingleDate(dateSpec DateSpec, times []TimeOfDay, loc *time.Location, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	nowDate := dateOnly(nowInTz)

	switch dateSpec.Kind {
	case DateSpecKindISO:
		targetDate, _ := parseISODate(dateSpec.Date)
		if targetDate.After(nowDate) {
			return nil // Future date
		}
		if targetDate.Year() == nowDate.Year() && targetDate.Month() == nowDate.Month() && targetDate.Day() == nowDate.Day() {
			return latestPastAtTimes(targetDate, times, loc, now)
		}
		return latestAtTimes(targetDate, times, loc)
	case DateSpecKindNamed:
		// Find most recent occurrence
		thisYear := time.Date(nowDate.Year(), time.Month(dateSpec.Month.Number()), dateSpec.Day, 0, 0, 0, 0, time.UTC)
		lastYear := time.Date(nowDate.Year()-1, time.Month(dateSpec.Month.Number()), dateSpec.Day, 0, 0, 0, 0, time.UTC)

		// Validate dates
		thisYearValid := thisYear.Month() == time.Month(dateSpec.Month.Number()) && thisYear.Day() == dateSpec.Day
		lastYearValid := lastYear.Month() == time.Month(dateSpec.Month.Number()) && lastYear.Day() == dateSpec.Day

		if thisYearValid && thisYear.Before(nowDate) {
			return latestAtTimes(thisYear, times, loc)
		}
		if thisYearValid && thisYear.Year() == nowDate.Year() && thisYear.Month() == nowDate.Month() && thisYear.Day() == nowDate.Day() {
			candidate := latestPastAtTimes(thisYear, times, loc, now)
			if candidate != nil {
				return candidate
			}
			if lastYearValid {
				return latestAtTimes(lastYear, times, loc)
			}
			return nil
		}
		if lastYearValid {
			return latestAtTimes(lastYear, times, loc)
		}
		return nil
	}

	return nil
}

func prevYearRepeat(interval int, target YearTarget, times []TimeOfDay, loc *time.Location, anchor string, now time.Time) *time.Time {
	nowInTz := now.In(loc)
	startDate := dateOnly(nowInTz)
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
		year := startYear - y

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
			if targetDate.After(startDate) {
				continue // Future
			}
			if targetDate.Year() == startDate.Year() && targetDate.Month() == startDate.Month() && targetDate.Day() == startDate.Day() {
				candidate := latestPastAtTimes(targetDate, times, loc, now)
				if candidate != nil {
					return candidate
				}
			} else {
				candidate := latestAtTimes(targetDate, times, loc)
				if candidate != nil {
					return candidate
				}
			}
		}
	}

	return nil
}
