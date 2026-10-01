package hron

import (
	"iter"
	"time"
)

// Supported instants are rangeStart <= t < rangeEnd; nothing outside them is
// an occurrence or a valid input (spec/README.md, "Supported range").
var (
	rangeStart = time.Date(1, 1, 2, 0, 0, 0, 0, time.UTC)
	rangeEnd   = time.Date(9999, 12, 30, 0, 0, 0, 0, time.UTC)
)

func inRange(t time.Time) bool {
	return !t.Before(rangeStart) && t.Before(rangeEnd)
}

// occurrence is an instant and the date it was scheduled on. A time shifted
// forward by a DST gap can land on the next date, but the day filter and the
// during, except and until clauses see its scheduled date (spec/README.md,
// "DST spring-forward (gaps)").
type occurrence struct {
	at   time.Time
	date time.Time
}

func nextFrom(schedule *ScheduleData, loc *time.Location, now time.Time) *time.Time {
	if !inRange(now) {
		return nil
	}
	if occ := firstAfter(schedule, loc, now); occ != nil {
		return &occ.at
	}
	return nil
}

// firstAfter returns the earliest occurrence strictly after now. It starts a
// day early because the previous date's time can be shifted past midnight.
func firstAfter(schedule *ScheduleData, loc *time.Location, now time.Time) *occurrence {
	return nextOccurrence(schedule, loc, now, dateOnly(now.In(loc)).AddDate(0, 0, -1))
}

// nextOccurrence returns the earliest occurrence strictly after now among those
// scheduled on or after startDate.
func nextOccurrence(schedule *ScheduleData, loc *time.Location, now, startDate time.Time) *occurrence {
	if schedule.Anchor != "" {
		anchorDate, _ := parseISODate(schedule.Anchor)
		if startDate.Before(anchorDate) {
			startDate = anchorDate
		}
	}
	var untilDate *time.Time
	if schedule.Until != nil {
		ud := dateOnly(resolveUntil(*schedule.Until, schedule.Anchor))
		untilDate = &ud
	}
	var targetDuring []MonthName
	if appliesDuringToTarget(schedule.Expr) {
		targetDuring = schedule.During
	}
	_, lastExcept := isoExceptBounds(schedule.Except, startDate)
	searchEnd := lastExcept.AddDate(horizonYears(schedule.Expr), 0, 0)

	for !startDate.After(searchEnd) && startDate.Before(rangeEnd) {
		occ := nextExpr(schedule.Expr, loc, schedule.Anchor, now, startDate, targetDuring)
		if occ == nil || !inRange(occ.at) {
			return nil
		}

		if untilDate != nil && occ.date.After(*untilDate) {
			return nil
		}

		if targetDuring == nil && !matchesDuring(occ.date, schedule.During) {
			startDate = nextDuringMonth(occ.date, schedule.During)
			continue
		}

		if isExcepted(occ.date, schedule.Except) {
			startDate = occ.date.AddDate(0, 0, 1)
			continue
		}

		if dateOnly(occ.at.In(loc)).After(occ.date) {
			// Shifted past midnight: a time scheduled on the landing date can come first.
			later := nextOccurrence(schedule, loc, now, occ.date.AddDate(0, 0, 1))
			if later != nil && later.at.Before(occ.at) {
				return later
			}
		}

		return occ
	}

	return nil
}

// appliesDuringToTarget reports whether during filters the target month rather
// than the date an occurrence lands on: a directional nearest weekday can
// cross into the adjacent month (spec/README.md, "Nearest weekday and during").
func appliesDuringToTarget(expr ScheduleExpr) bool {
	return expr.Kind == ScheduleExprKindMonth &&
		expr.MonthTarget.Kind == MonthTargetKindNearestWeekday &&
		expr.MonthTarget.Direction != NearestNone
}

// horizonYears is 400 for expressions whose interval is not a calendar unit,
// since the calendar itself repeats every 400 years.
func horizonYears(expr ScheduleExpr) int {
	units := unitsIn400Years(expr.Kind)
	if units == 0 {
		return 400
	}
	return ceilDiv(horizonUnits(calendarInterval(expr), units)*400, units)
}

// calendarInterval caps a day, week, month or year interval just beyond the
// supported range. Any larger interval aligns only the anchor inside the range,
// so the result is the same, and the cap keeps date arithmetic from overflowing.
func calendarInterval(expr ScheduleExpr) int {
	return min(expr.Interval, maxSearchYears/400*unitsIn400Years(expr.Kind)+1)
}

// unitsIn400Years returns how many of the expression's interval units make up
// 400 years, or 0 if its interval is not a calendar unit.
func unitsIn400Years(kind ScheduleExprKind) int {
	switch kind {
	case ScheduleExprKindDay:
		return 146097
	case ScheduleExprKindWeek:
		return 20871
	case ScheduleExprKindMonth:
		return 400 * 12
	case ScheduleExprKindYear:
		return 400
	default:
		return 0
	}
}

func nextExpr(expr ScheduleExpr, loc *time.Location, anchor string, now, startDate time.Time, targetDuring []MonthName) *occurrence {
	switch expr.Kind {
	case ScheduleExprKindDay:
		return nextDayRepeat(calendarInterval(expr), expr.Days, expr.Times, loc, anchor, now, startDate)
	case ScheduleExprKindInterval:
		return nextIntervalRepeat(expr.Interval, expr.Unit, expr.FromTime, expr.ToTime, expr.DayFilter, loc, now, startDate)
	case ScheduleExprKindWeek:
		return nextWeekRepeat(calendarInterval(expr), expr.WeekDays, expr.Times, loc, anchor, now, startDate)
	case ScheduleExprKindMonth:
		return nextMonthRepeat(calendarInterval(expr), expr.MonthTarget, expr.Times, loc, anchor, now, startDate, targetDuring)
	case ScheduleExprKindSingleDate:
		return nextSingleDate(expr.DateSpec, expr.Times, loc, now, startDate)
	case ScheduleExprKindYear:
		return nextYearRepeat(calendarInterval(expr), expr.YearTarget, expr.Times, loc, anchor, now, startDate)
	default:
		return nil
	}
}

// matches drops the seconds of dt and reports whether that minute is an
// occurrence, by the same rules nextFrom uses.
func matches(schedule *ScheduleData, loc *time.Location, dt time.Time) bool {
	local := dt.In(loc)
	minute := local.Add(-time.Duration(local.Second())*time.Second - time.Duration(local.Nanosecond()))
	if !inRange(minute) {
		return false
	}
	occ := firstAfter(schedule, loc, minute.Add(-time.Nanosecond))
	return occ != nil && occ.at.Equal(minute)
}

func nextDayRepeat(interval int, days DayFilter, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	d := startDate

	if interval <= 1 {
		// From the day before now's date (its time can be shifted past midnight) to a week after it.
		for i := 0; i < 9; i++ {
			if matchesDayFilter(d, days) {
				if occ := earliestFutureAtTimes(d, times, loc, now, startDate); occ != nil {
					return occ
				}
			}
			d = d.AddDate(0, 0, 1)
		}

		return nil
	}

	// Interval > 1: day intervals only apply to DayFilter::Every
	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	offset := daysBetween(dateOnly(anchorDate), d)
	alignedDate := d.AddDate(0, 0, floorMod(-offset, interval))

	for i := 0; i < 3; i++ {
		if occ := earliestFutureAtTimes(alignedDate, times, loc, now, startDate); occ != nil {
			return occ
		}
		alignedDate = alignedDate.AddDate(0, 0, interval)
	}

	return nil
}

func nextIntervalRepeat(interval int, unit IntervalUnit, fromTime, toTime TimeOfDay, dayFilter *DayFilter, loc *time.Location, now, startDate time.Time) *occurrence {
	nowInTz := now.In(loc)
	stepMinutes := intervalStepMinutes(interval, unit)
	fromMinutes := fromTime.TotalMinutes()
	toMinutes := toTime.TotalMinutes()
	nowMinutes := nowInTz.Hour()*60 + nowInTz.Minute()

	// Interval slots are never shifted, so none scheduled before today is after now.
	today := dateOnly(nowInTz)
	d := startDate
	if d.Before(today) {
		d = today
	}

	// Two weeks, since a window wholly inside a DST gap, or a skipped day (Pacific/Apia,
	// 2011-12-30), leaves a filtered day with no slot.
	for i := 0; i < 15; i++ {
		if dayFilter == nil || matchesDayFilter(d, *dayFilter) {
			firstSlot := fromMinutes
			if d.Equal(today) && nowMinutes >= fromMinutes {
				firstSlot = fromMinutes + ((nowMinutes-fromMinutes)/stepMinutes+1)*stepMinutes
			}
			// Later slots can still be past when now is in the second pass of a fall-back overlap.
			for slot := firstSlot; slot <= toMinutes; slot += stepMinutes {
				at, exists := resolveWallClock(d, TimeOfDay{slot / 60, slot % 60}, loc)
				if exists && at.After(now) {
					return &occurrence{at, d}
				}
			}
		}
		d = d.AddDate(0, 0, 1)
	}

	return nil
}

// intervalStepMinutes caps the step at a day, since a step of a day or more
// leaves only the from slot; the cap also keeps huge intervals from overflowing.
func intervalStepMinutes(interval int, unit IntervalUnit) int {
	const day = 24 * 60
	if unit == IntervalHours {
		return min(interval, 24) * 60
	}
	return min(interval, day)
}

func nextWeekRepeat(interval int, days []Weekday, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	anchorDate := epochMonday
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	sortedDays := make([]Weekday, len(days))
	copy(sortedDays, days)
	for i := 0; i < len(sortedDays)-1; i++ {
		for j := i + 1; j < len(sortedDays); j++ {
			if sortedDays[i].Number() > sortedDays[j].Number() {
				sortedDays[i], sortedDays[j] = sortedDays[j], sortedDays[i]
			}
		}
	}

	currentMonday := startDate.AddDate(0, 0, -(isoWeekday(startDate) - 1))
	anchorMonday := anchorDate.AddDate(0, 0, -(isoWeekday(anchorDate) - 1))

	for i := 0; i < 54; i++ {
		weeks := weeksBetween(dateOnly(anchorMonday), currentMonday)

		if floorMod(weeks, interval) == 0 {
			for _, wd := range sortedDays {
				targetDate := currentMonday.AddDate(0, 0, wd.Number()-1)
				if occ := earliestFutureAtTimes(targetDate, times, loc, now, startDate); occ != nil {
					return occ
				}
			}
		}

		remainder := floorMod(weeks, interval)
		skipWeeks := interval
		if remainder != 0 {
			skipWeeks = interval - remainder
		}
		currentMonday = currentMonday.AddDate(0, 0, skipWeeks*7)
	}

	return nil
}

// nextMonthRepeat filters target months by targetDuring when it is non-nil.
func nextMonthRepeat(interval int, target MonthTarget, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time, targetDuring []MonthName) *occurrence {
	// Start a month early: a directional nearest weekday can land in the month after its target.
	month := monthIndex(startDate) - 1
	if interval > 1 {
		anchorDate := epochDate
		if anchor != "" {
			anchorDate, _ = parseISODate(anchor)
		}
		month += floorMod(monthIndex(anchorDate)-month, interval)
	}

	for i := 0; i <= searchSteps(interval, unitsIn400Years(ScheduleExprKindMonth)); i++ {
		first := time.Date(0, time.Month(month+1), 1, 0, 0, 0, 0, time.UTC)
		if matchesDuring(first, targetDuring) {
			var best *occurrence
			for _, d := range monthTargetDates(first.Year(), first.Month(), target) {
				occ := earliestFutureAtTimes(d, times, loc, now, startDate)
				if occ != nil && (best == nil || occ.at.Before(best.at)) {
					best = occ
				}
			}
			if best != nil {
				return best
			}
		}
		month += max(interval, 1)
	}

	return nil
}

func nextSingleDate(dateSpec DateSpec, times []TimeOfDay, loc *time.Location, now, startDate time.Time) *occurrence {
	switch dateSpec.Kind {
	case DateSpecKindISO:
		d, _ := parseISODate(dateSpec.Date)
		return earliestFutureAtTimes(d, times, loc, now, startDate)
	case DateSpecKindNamed:
		// Consecutive Feb 29s can be eight years apart (2096, 2104).
		for year := startDate.Year(); year <= startDate.Year()+8; year++ {
			d, ok := namedDate(year, dateSpec)
			if !ok {
				continue
			}
			if occ := earliestFutureAtTimes(d, times, loc, now, startDate); occ != nil {
				return occ
			}
		}
	}

	return nil
}

func nextYearRepeat(interval int, target YearTarget, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	year := startDate.Year()
	if interval > 1 {
		anchorYear := epochDate.Year()
		if anchor != "" {
			anchorDate, _ := parseISODate(anchor)
			anchorYear = anchorDate.Year()
		}
		year += floorMod(anchorYear-year, interval)
	}

	for i := 0; i <= searchSteps(interval, unitsIn400Years(ScheduleExprKindYear)); i++ {
		if d, ok := yearTargetDate(year, target); ok {
			if occ := earliestFutureAtTimes(d, times, loc, now, startDate); occ != nil {
				return occ
			}
		}
		year += max(interval, 1)
	}

	return nil
}

// Occurrences returns a lazy iterator of occurrences strictly after from.
// Unbounded for repeating schedules unless an until clause ends them.
func Occurrences(schedule *Schedule, from time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		current := from
		for {
			next := schedule.NextFrom(current)
			if next == nil {
				return
			}
			current = *next
			if !yield(*next) {
				return
			}
		}
	}
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
func Between(schedule *Schedule, from, to time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		if !inRange(to) {
			return
		}
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

func previousFrom(schedule *ScheduleData, loc *time.Location, now time.Time) *time.Time {
	if !inRange(now) {
		return nil
	}
	// Start a day late: a fall-back overlap crossing midnight repeats the
	// previous date after the next date's first times have passed.
	startDate := dateOnly(now.In(loc)).AddDate(0, 0, 1)
	if occ := previousOccurrence(schedule, loc, now, startDate); occ != nil {
		return &occ.at
	}
	return nil
}

// previousOccurrence returns the latest occurrence strictly before now among
// those scheduled on or before startDate.
func previousOccurrence(schedule *ScheduleData, loc *time.Location, now, startDate time.Time) *occurrence {
	var anchorDate *time.Time
	if schedule.Anchor != "" {
		ad, _ := parseISODate(schedule.Anchor)
		anchorDate = &ad
	}
	if schedule.Until != nil {
		untilDate := dateOnly(resolveUntil(*schedule.Until, schedule.Anchor))
		if startDate.After(untilDate) {
			startDate = untilDate
		}
	}
	var targetDuring []MonthName
	if appliesDuringToTarget(schedule.Expr) {
		targetDuring = schedule.During
	}
	firstExcept, _ := isoExceptBounds(schedule.Except, startDate)
	searchEnd := firstExcept.AddDate(-horizonYears(schedule.Expr), 0, 0)

	for !startDate.Before(searchEnd) && !startDate.Before(rangeStart.AddDate(0, 0, -1)) {
		occ := prevExpr(schedule.Expr, loc, schedule.Anchor, now, startDate, targetDuring)
		if occ == nil || !inRange(occ.at) {
			return nil
		}

		if anchorDate != nil && occ.date.Before(*anchorDate) {
			return nil
		}

		if targetDuring == nil && !matchesDuring(occ.date, schedule.During) {
			startDate = prevDuringMonth(occ.date, schedule.During)
			continue
		}

		if isExcepted(occ.date, schedule.Except) {
			startDate = occ.date.AddDate(0, 0, -1)
			continue
		}

		dayBefore := occ.date.AddDate(0, 0, -1)
		if _, exists := resolveWallClock(dayBefore, TimeOfDay{23, 59}, loc); !exists {
			// The day before ends in a gap, so its times can be shifted onto this date after occ.
			earlier := previousOccurrence(schedule, loc, now, dayBefore)
			if earlier != nil && earlier.at.After(occ.at) {
				return earlier
			}
		}

		return occ
	}

	return nil
}

func prevExpr(expr ScheduleExpr, loc *time.Location, anchor string, now, startDate time.Time, targetDuring []MonthName) *occurrence {
	switch expr.Kind {
	case ScheduleExprKindDay:
		return prevDayRepeat(calendarInterval(expr), expr.Days, expr.Times, loc, anchor, now, startDate)
	case ScheduleExprKindInterval:
		return prevIntervalRepeat(expr.Interval, expr.Unit, expr.FromTime, expr.ToTime, expr.DayFilter, loc, now, startDate)
	case ScheduleExprKindWeek:
		return prevWeekRepeat(calendarInterval(expr), expr.WeekDays, expr.Times, loc, anchor, now, startDate)
	case ScheduleExprKindMonth:
		return prevMonthRepeat(calendarInterval(expr), expr.MonthTarget, expr.Times, loc, anchor, now, startDate, targetDuring)
	case ScheduleExprKindSingleDate:
		return prevSingleDate(expr.DateSpec, expr.Times, loc, now, startDate)
	case ScheduleExprKindYear:
		return prevYearRepeat(calendarInterval(expr), expr.YearTarget, expr.Times, loc, anchor, now, startDate)
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

// latestPastAtTimes finds the latest of times on date d that is strictly
// before now, if d is not after startDate.
func latestPastAtTimes(d time.Time, times []TimeOfDay, loc *time.Location, now, startDate time.Time) *occurrence {
	if d.After(startDate) {
		return nil
	}
	var best *occurrence
	for _, tod := range times {
		at := atTimeOnDate(d, tod, loc)
		if at.Before(now) && (best == nil || at.After(best.at)) {
			best = &occurrence{at, d}
		}
	}
	return best
}

func prevDayRepeat(interval int, days DayFilter, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	d := startDate

	if interval <= 1 {
		// From the day after now's date back to eight days before it: a time
		// shifted onto now's date can equal now, leaving the previous one eight days back.
		for i := 0; i < 10; i++ {
			if matchesDayFilter(d, days) {
				if occ := latestPastAtTimes(d, times, loc, now, startDate); occ != nil {
					return occ
				}
			}
			d = d.AddDate(0, 0, -1)
		}

		return nil
	}

	anchorDate := epochDate
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	offset := daysBetween(dateOnly(anchorDate), d)
	alignedDate := d.AddDate(0, 0, -floorMod(offset, interval))

	for i := 0; i < 3; i++ {
		if occ := latestPastAtTimes(alignedDate, times, loc, now, startDate); occ != nil {
			return occ
		}
		alignedDate = alignedDate.AddDate(0, 0, -interval)
	}

	return nil
}

func prevIntervalRepeat(interval int, unit IntervalUnit, fromTime, toTime TimeOfDay, dayFilter *DayFilter, loc *time.Location, now, startDate time.Time) *occurrence {
	nowInTz := now.In(loc)
	stepMinutes := intervalStepMinutes(interval, unit)
	fromMinutes := fromTime.TotalMinutes()
	lastSlot := fromMinutes + (toTime.TotalMinutes()-fromMinutes)/stepMinutes*stepMinutes

	// Today, slots after now's wall time are still ahead, unless now is in the
	// second pass of a fall-back overlap, where they already passed.
	today := dateOnly(nowInTz)
	todayLastSlot := lastSlot
	nowMinutes := nowInTz.Hour()*60 + nowInTz.Minute()
	if firstPass, _ := resolveWallClock(today, TimeOfDay{nowInTz.Hour(), nowInTz.Minute()}, loc); now.Before(firstPass.Add(time.Minute)) {
		todayLastSlot = min(lastSlot, fromMinutes+floorDiv(nowMinutes-fromMinutes, stepMinutes)*stepMinutes)
	}

	d := startDate
	// From the day after now's date back two weeks, since a window wholly inside a DST gap,
	// or a skipped day (Pacific/Apia, 2011-12-30), leaves a filtered day with no slot.
	for i := 0; i < 16; i++ {
		if dayFilter == nil || matchesDayFilter(d, *dayFilter) {
			top := lastSlot
			switch {
			case d.Equal(today):
				top = todayLastSlot
			case d.After(today):
				// A later date's slots are past only in an overlap crossing midnight.
				if first, _ := resolveWallClock(d, fromTime, loc); !first.Before(now) {
					top = fromMinutes - 1
				}
			}
			for slot := top; slot >= fromMinutes; slot -= stepMinutes {
				at, exists := resolveWallClock(d, TimeOfDay{slot / 60, slot % 60}, loc)
				if exists && at.Before(now) {
					return &occurrence{at, d}
				}
			}
		}
		d = d.AddDate(0, 0, -1)
	}

	return nil
}

func prevWeekRepeat(interval int, days []Weekday, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	anchorDate := epochMonday
	if anchor != "" {
		anchorDate, _ = parseISODate(anchor)
	}

	sortedDays := make([]Weekday, len(days))
	copy(sortedDays, days)
	for i := 0; i < len(sortedDays)-1; i++ {
		for j := i + 1; j < len(sortedDays); j++ {
			if sortedDays[i].Number() < sortedDays[j].Number() {
				sortedDays[i], sortedDays[j] = sortedDays[j], sortedDays[i]
			}
		}
	}

	currentMonday := startDate.AddDate(0, 0, -(isoWeekday(startDate) - 1))
	anchorMonday := anchorDate.AddDate(0, 0, -(isoWeekday(anchorDate) - 1))

	for i := 0; i < 54; i++ {
		weeks := weeksBetween(dateOnly(anchorMonday), currentMonday)

		if floorMod(weeks, interval) == 0 {
			for _, wd := range sortedDays {
				targetDate := currentMonday.AddDate(0, 0, wd.Number()-1)
				if occ := latestPastAtTimes(targetDate, times, loc, now, startDate); occ != nil {
					return occ
				}
			}
		}

		remainder := floorMod(weeks, interval)
		skipWeeks := interval
		if remainder != 0 {
			skipWeeks = remainder
		}
		currentMonday = currentMonday.AddDate(0, 0, -skipWeeks*7)
	}

	return nil
}

// prevMonthRepeat filters target months by targetDuring when it is non-nil.
func prevMonthRepeat(interval int, target MonthTarget, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time, targetDuring []MonthName) *occurrence {
	// Start a month late: a directional nearest weekday can land in the month before its target.
	month := monthIndex(startDate) + 1
	if interval > 1 {
		anchorDate := epochDate
		if anchor != "" {
			anchorDate, _ = parseISODate(anchor)
		}
		month -= floorMod(month-monthIndex(anchorDate), interval)
	}

	for i := 0; i <= searchSteps(interval, unitsIn400Years(ScheduleExprKindMonth)); i++ {
		first := time.Date(0, time.Month(month+1), 1, 0, 0, 0, 0, time.UTC)
		if matchesDuring(first, targetDuring) {
			var best *occurrence
			for _, d := range monthTargetDates(first.Year(), first.Month(), target) {
				occ := latestPastAtTimes(d, times, loc, now, startDate)
				if occ != nil && (best == nil || occ.at.After(best.at)) {
					best = occ
				}
			}
			if best != nil {
				return best
			}
		}
		month -= max(interval, 1)
	}

	return nil
}

func prevSingleDate(dateSpec DateSpec, times []TimeOfDay, loc *time.Location, now, startDate time.Time) *occurrence {
	switch dateSpec.Kind {
	case DateSpecKindISO:
		d, _ := parseISODate(dateSpec.Date)
		return latestPastAtTimes(d, times, loc, now, startDate)
	case DateSpecKindNamed:
		// Consecutive Feb 29s can be eight years apart (2096, 2104).
		for year := startDate.Year(); year >= startDate.Year()-8; year-- {
			d, ok := namedDate(year, dateSpec)
			if !ok {
				continue
			}
			if occ := latestPastAtTimes(d, times, loc, now, startDate); occ != nil {
				return occ
			}
		}
	}

	return nil
}

func prevYearRepeat(interval int, target YearTarget, times []TimeOfDay, loc *time.Location, anchor string, now, startDate time.Time) *occurrence {
	year := startDate.Year()
	if interval > 1 {
		anchorYear := epochDate.Year()
		if anchor != "" {
			anchorDate, _ := parseISODate(anchor)
			anchorYear = anchorDate.Year()
		}
		year -= floorMod(year-anchorYear, interval)
	}

	for i := 0; i <= searchSteps(interval, unitsIn400Years(ScheduleExprKindYear)); i++ {
		if d, ok := yearTargetDate(year, target); ok {
			if occ := latestPastAtTimes(d, times, loc, now, startDate); occ != nil {
				return occ
			}
		}
		year -= max(interval, 1)
	}

	return nil
}
