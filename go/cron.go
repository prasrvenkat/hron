package hron

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// ToCron converts a schedule to a 5-field cron expression.
func ToCron(schedule *ScheduleData) (string, error) {
	if len(schedule.Except) > 0 {
		return "", CronError("not expressible as cron (except clauses not supported)")
	}
	if schedule.Until != nil {
		return "", CronError("not expressible as cron (until clauses not supported)")
	}
	if len(schedule.During) > 0 {
		return "", CronError("not expressible as cron (during clauses not supported)")
	}

	expr := schedule.Expr

	switch expr.Kind {
	case ScheduleExprKindDay:
		if expr.Interval > 1 {
			return "", CronError("not expressible as cron (multi-day intervals not supported)")
		}
		if len(expr.Times) != 1 {
			return "", CronError("not expressible as cron (multiple times not supported)")
		}
		t := expr.Times[0]
		dow := dayFilterToCronDOW(expr.Days)
		return fmt.Sprintf("%d %d * * %s", t.Minute, t.Hour, dow), nil

	case ScheduleExprKindInterval:
		fullDay := expr.FromTime.Hour == 0 && expr.FromTime.Minute == 0 && expr.ToTime.Hour == 23 && expr.ToTime.Minute == 59
		if !fullDay {
			return "", CronError("not expressible as cron (partial-day interval windows not supported)")
		}
		if expr.DayFilter != nil {
			return "", CronError("not expressible as cron (interval with day filter not supported)")
		}
		if expr.Unit == IntervalMin {
			if 60%expr.Interval != 0 {
				return "", CronError(fmt.Sprintf("not expressible as cron (*/%d breaks at hour boundaries)", expr.Interval))
			}
			return fmt.Sprintf("*/%d * * * *", expr.Interval), nil
		}
		// hours
		return fmt.Sprintf("0 */%d * * *", expr.Interval), nil

	case ScheduleExprKindWeek:
		return "", CronError("not expressible as cron (multi-week intervals not supported)")

	case ScheduleExprKindMonth:
		if expr.Interval > 1 {
			return "", CronError("not expressible as cron (multi-month intervals not supported)")
		}
		if len(expr.Times) != 1 {
			return "", CronError("not expressible as cron (multiple times not supported)")
		}
		t := expr.Times[0]
		switch expr.MonthTarget.Kind {
		case MonthTargetKindDays:
			var expanded []int
			for _, spec := range expr.MonthTarget.Specs {
				expanded = append(expanded, spec.Expand()...)
			}
			dom := formatIntList(expanded)
			return fmt.Sprintf("%d %d %s * *", t.Minute, t.Hour, dom), nil
		case MonthTargetKindLastDay:
			return "", CronError("not expressible as cron (last day of month not supported)")
		case MonthTargetKindLastWeekday:
			return "", CronError("not expressible as cron (last weekday of month not supported)")
		}

	case ScheduleExprKindOrdinal:
		return "", CronError("not expressible as cron (ordinal weekday of month not supported)")

	case ScheduleExprKindSingleDate:
		return "", CronError("not expressible as cron (single dates are not repeating)")

	case ScheduleExprKindYear:
		return "", CronError("not expressible as cron (yearly schedules not supported in 5-field cron)")
	}

	return "", CronError(fmt.Sprintf("unknown expression type: %d", expr.Kind))
}

func dayFilterToCronDOW(f DayFilter) string {
	switch f.Kind {
	case DayFilterKindEvery:
		return "*"
	case DayFilterKindWeekday:
		return "1-5"
	case DayFilterKindWeekend:
		return "0,6"
	case DayFilterKindDays:
		nums := make([]int, len(f.Days))
		for i, d := range f.Days {
			nums[i] = d.CronDOW()
		}
		sort.Ints(nums)
		return formatIntList(nums)
	default:
		return "*"
	}
}

func formatIntList(nums []int) string {
	parts := make([]string, len(nums))
	for i, n := range nums {
		parts[i] = strconv.Itoa(n)
	}
	return strings.Join(parts, ",")
}

// FromCron converts a 5-field cron expression to a Schedule.
func FromCron(cron string) (*ScheduleData, error) {
	cron = strings.TrimSpace(cron)

	// Handle @ shortcuts first
	if strings.HasPrefix(cron, "@") {
		return parseCronShortcut(cron)
	}

	fields := strings.Fields(cron)
	if len(fields) != 5 {
		return nil, CronError(fmt.Sprintf("expected 5 cron fields, got %d", len(fields)))
	}

	minuteField := fields[0]
	hourField := fields[1]
	domField := fields[2]
	monthField := fields[3]
	dowField := fields[4]

	// Normalize ? to * (they're semantically equivalent for our purposes)
	if domField == "?" {
		domField = "*"
	}
	if dowField == "?" {
		dowField = "*"
	}

	// Parse month field into during clause
	during, err := parseMonthField(monthField)
	if err != nil {
		return nil, err
	}

	// Check for special DOW patterns: nth weekday (#), last weekday (5L)
	schedule, handled, err := tryParseNthWeekday(minuteField, hourField, domField, dowField, during)
	if err != nil {
		return nil, err
	}
	if handled {
		return schedule, nil
	}

	// Check for L (last day) or LW (last weekday) in DOM
	schedule, handled, err = tryParseLastDay(minuteField, hourField, domField, dowField, during)
	if err != nil {
		return nil, err
	}
	if handled {
		return schedule, nil
	}

	// Check for W (nearest weekday) - not yet supported
	if strings.HasSuffix(domField, "W") && domField != "LW" {
		return nil, CronError("W (nearest weekday) not yet supported")
	}

	// Check for interval patterns: */N or range/N
	schedule, handled, err = tryParseInterval(minuteField, hourField, domField, dowField, during)
	if err != nil {
		return nil, err
	}
	if handled {
		return schedule, nil
	}

	// Standard time-based cron
	minute, err := parseSingleValue(minuteField, "minute", 0, 59)
	if err != nil {
		return nil, err
	}
	hour, err := parseSingleValue(hourField, "hour", 0, 23)
	if err != nil {
		return nil, err
	}
	t := TimeOfDay{hour, minute}

	// DOM-based (monthly) - when DOM is specified and DOW is *
	if domField != "*" && dowField == "*" {
		target, err := parseDOMField(domField)
		if err != nil {
			return nil, err
		}
		schedule := NewScheduleData(NewMonthRepeat(1, target, []TimeOfDay{t}))
		schedule.During = during
		return schedule, nil
	}

	// DOW-based (day repeat)
	days, err := parseCronDOW(dowField)
	if err != nil {
		return nil, err
	}
	schedule = NewScheduleData(NewDayRepeat(1, days, []TimeOfDay{t}))
	schedule.During = during
	return schedule, nil
}

// parseCronShortcut parses @ shortcuts like @daily, @hourly, etc.
func parseCronShortcut(cron string) (*ScheduleData, error) {
	switch strings.ToLower(cron) {
	case "@yearly", "@annually":
		return NewScheduleData(NewYearRepeat(1, NewYearDateTarget(Jan, 1), []TimeOfDay{{0, 0}})), nil
	case "@monthly":
		return NewScheduleData(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(1)}), []TimeOfDay{{0, 0}})), nil
	case "@weekly":
		return NewScheduleData(NewDayRepeat(1, NewDayFilterDays([]Weekday{Sunday}), []TimeOfDay{{0, 0}})), nil
	case "@daily", "@midnight":
		return NewScheduleData(NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{0, 0}})), nil
	case "@hourly":
		return NewScheduleData(NewIntervalRepeat(1, IntervalHours, TimeOfDay{0, 0}, TimeOfDay{23, 59}, nil)), nil
	default:
		return nil, CronError(fmt.Sprintf("unknown @ shortcut: %s", cron))
	}
}

// parseMonthField parses the month field into a []MonthName for the `during` clause.
func parseMonthField(field string) ([]MonthName, error) {
	if field == "*" {
		return nil, nil
	}

	var months []MonthName
	for _, part := range strings.Split(field, ",") {
		// Check for step values FIRST (e.g., 1-12/3 or */3)
		if strings.Contains(part, "/") {
			rangePart, stepStr, _ := strings.Cut(part, "/")
			var start, end int
			if rangePart == "*" {
				start, end = 1, 12
			} else if strings.Contains(rangePart, "-") {
				s, e, _ := strings.Cut(rangePart, "-")
				startMonth, err := parseMonthValue(s)
				if err != nil {
					return nil, err
				}
				endMonth, err := parseMonthValue(e)
				if err != nil {
					return nil, err
				}
				start, end = startMonth.Number(), endMonth.Number()
			} else {
				return nil, CronError(fmt.Sprintf("invalid month step expression: %s", part))
			}
			step, err := strconv.Atoi(stepStr)
			if err != nil {
				return nil, CronError(fmt.Sprintf("invalid month step value: %s", stepStr))
			}
			if step == 0 {
				return nil, CronError("step cannot be 0")
			}
			for n := start; n <= end; n += step {
				m, err := monthFromNumber(n)
				if err != nil {
					return nil, err
				}
				months = append(months, m)
			}
		} else if strings.Contains(part, "-") {
			// Range like 1-3 or JAN-MAR
			startStr, endStr, _ := strings.Cut(part, "-")
			startMonth, err := parseMonthValue(startStr)
			if err != nil {
				return nil, err
			}
			endMonth, err := parseMonthValue(endStr)
			if err != nil {
				return nil, err
			}
			startNum, endNum := startMonth.Number(), endMonth.Number()
			if startNum > endNum {
				return nil, CronError(fmt.Sprintf("invalid month range: %s > %s", startStr, endStr))
			}
			for n := startNum; n <= endNum; n++ {
				m, err := monthFromNumber(n)
				if err != nil {
					return nil, err
				}
				months = append(months, m)
			}
		} else {
			// Single month
			m, err := parseMonthValue(part)
			if err != nil {
				return nil, err
			}
			months = append(months, m)
		}
	}

	return months, nil
}

// parseMonthValue parses a single month value (number 1-12 or name JAN-DEC).
func parseMonthValue(s string) (MonthName, error) {
	// Try as number first
	if n, err := strconv.Atoi(s); err == nil {
		return monthFromNumber(n)
	}
	// Try as name
	if m, ok := ParseMonthName(s); ok {
		return m, nil
	}
	return 0, CronError(fmt.Sprintf("invalid month: %s", s))
}

func monthFromNumber(n int) (MonthName, error) {
	if n < 1 || n > 12 {
		return 0, CronError(fmt.Sprintf("invalid month number: %d", n))
	}
	return MonthName(n), nil
}

// tryParseNthWeekday tries to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday).
func tryParseNthWeekday(minuteField, hourField, domField, dowField string, during []MonthName) (*ScheduleData, bool, error) {
	// Check for # pattern (nth weekday of month)
	if strings.Contains(dowField, "#") {
		dowStr, nthStr, _ := strings.Cut(dowField, "#")
		dowNum, err := parseDOWValue(dowStr)
		if err != nil {
			return nil, false, err
		}
		weekday, err := cronDOWToWeekday(dowNum)
		if err != nil {
			return nil, false, err
		}
		nth, err := strconv.Atoi(nthStr)
		if err != nil {
			return nil, false, CronError(fmt.Sprintf("invalid nth value: %s", nthStr))
		}
		if nth < 1 || nth > 5 {
			return nil, false, CronError(fmt.Sprintf("nth must be 1-5, got %d", nth))
		}
		var ordinal OrdinalPosition
		switch nth {
		case 1:
			ordinal = First
		case 2:
			ordinal = Second
		case 3:
			ordinal = Third
		case 4:
			ordinal = Fourth
		case 5:
			ordinal = Fifth
		}

		if domField != "*" && domField != "?" {
			return nil, false, CronError("DOM must be * when using # for nth weekday")
		}

		minute, err := parseSingleValue(minuteField, "minute", 0, 59)
		if err != nil {
			return nil, false, err
		}
		hour, err := parseSingleValue(hourField, "hour", 0, 23)
		if err != nil {
			return nil, false, err
		}

		schedule := NewScheduleData(NewOrdinalRepeat(1, ordinal, weekday, []TimeOfDay{{hour, minute}}))
		schedule.During = during
		return schedule, true, nil
	}

	// Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
	if strings.HasSuffix(dowField, "L") && len(dowField) > 1 {
		dowStr := dowField[:len(dowField)-1]
		dowNum, err := parseDOWValue(dowStr)
		if err != nil {
			return nil, false, err
		}
		weekday, err := cronDOWToWeekday(dowNum)
		if err != nil {
			return nil, false, err
		}

		if domField != "*" && domField != "?" {
			return nil, false, CronError("DOM must be * when using nL for last weekday")
		}

		minute, err := parseSingleValue(minuteField, "minute", 0, 59)
		if err != nil {
			return nil, false, err
		}
		hour, err := parseSingleValue(hourField, "hour", 0, 23)
		if err != nil {
			return nil, false, err
		}

		schedule := NewScheduleData(NewOrdinalRepeat(1, Last, weekday, []TimeOfDay{{hour, minute}}))
		schedule.During = during
		return schedule, true, nil
	}

	return nil, false, nil
}

// tryParseLastDay tries to parse L (last day) or LW (last weekday) patterns.
func tryParseLastDay(minuteField, hourField, domField, dowField string, during []MonthName) (*ScheduleData, bool, error) {
	if domField != "L" && domField != "LW" {
		return nil, false, nil
	}

	if dowField != "*" && dowField != "?" {
		return nil, false, CronError("DOW must be * when using L or LW in DOM")
	}

	minute, err := parseSingleValue(minuteField, "minute", 0, 59)
	if err != nil {
		return nil, false, err
	}
	hour, err := parseSingleValue(hourField, "hour", 0, 23)
	if err != nil {
		return nil, false, err
	}

	var target MonthTarget
	if domField == "LW" {
		target = NewLastWeekdayTarget()
	} else {
		target = NewLastDayTarget()
	}

	schedule := NewScheduleData(NewMonthRepeat(1, target, []TimeOfDay{{hour, minute}}))
	schedule.During = during
	return schedule, true, nil
}

// tryParseInterval tries to parse interval patterns: */N, range/N in minute or hour fields.
func tryParseInterval(minuteField, hourField, domField, dowField string, during []MonthName) (*ScheduleData, bool, error) {
	// Minute interval: */N or range/N
	if strings.Contains(minuteField, "/") {
		rangePart, stepStr, _ := strings.Cut(minuteField, "/")
		interval, err := strconv.Atoi(stepStr)
		if err != nil {
			return nil, false, CronError("invalid minute interval value")
		}
		if interval == 0 {
			return nil, false, CronError("step cannot be 0")
		}

		var fromMinute, toMinute int
		if rangePart == "*" {
			fromMinute, toMinute = 0, 59
		} else if strings.Contains(rangePart, "-") {
			startStr, endStr, _ := strings.Cut(rangePart, "-")
			s, err := strconv.Atoi(startStr)
			if err != nil {
				return nil, false, CronError("invalid minute range")
			}
			e, err := strconv.Atoi(endStr)
			if err != nil {
				return nil, false, CronError("invalid minute range")
			}
			if s > e {
				return nil, false, CronError(fmt.Sprintf("range start must be <= end: %d-%d", s, e))
			}
			fromMinute, toMinute = s, e
		} else {
			// Single value with step (e.g., 0/15) - treat as starting point
			s, err := strconv.Atoi(rangePart)
			if err != nil {
				return nil, false, CronError("invalid minute value")
			}
			fromMinute, toMinute = s, 59
		}

		// Determine the hour window
		var fromHour, toHour int
		if hourField == "*" {
			fromHour, toHour = 0, 23
		} else if strings.Contains(hourField, "-") {
			startStr, endStr, _ := strings.Cut(hourField, "-")
			s, err := strconv.Atoi(startStr)
			if err != nil {
				return nil, false, CronError("invalid hour range")
			}
			e, err := strconv.Atoi(endStr)
			if err != nil {
				return nil, false, CronError("invalid hour range")
			}
			fromHour, toHour = s, e
		} else if strings.Contains(hourField, "/") {
			// Hour also has step - this is complex, handle as hour interval
			return nil, false, nil
		} else {
			h, err := strconv.Atoi(hourField)
			if err != nil {
				return nil, false, CronError("invalid hour")
			}
			fromHour, toHour = h, h
		}

		// Check if this should be a day filter
		var dayFilter *DayFilter
		if dowField != "*" {
			df, err := parseCronDOW(dowField)
			if err != nil {
				return nil, false, err
			}
			dayFilter = &df
		}

		if domField == "*" || domField == "?" {
			// Determine the end minute based on context
			var endMinute int
			if fromMinute == 0 && toMinute == 59 && toHour == 23 {
				// Full day: 00:00 to 23:59
				endMinute = 59
			} else if fromMinute == 0 && toMinute == 59 {
				// Partial day with full minutes range: use :00 for cleaner output
				endMinute = 0
			} else {
				endMinute = toMinute
			}

			schedule := NewScheduleData(NewIntervalRepeat(
				interval,
				IntervalMin,
				TimeOfDay{fromHour, fromMinute},
				TimeOfDay{toHour, endMinute},
				dayFilter,
			))
			schedule.During = during
			return schedule, true, nil
		}
	}

	// Hour interval: 0 */N or 0 range/N
	if strings.Contains(hourField, "/") && (minuteField == "0" || minuteField == "00") {
		rangePart, stepStr, _ := strings.Cut(hourField, "/")
		interval, err := strconv.Atoi(stepStr)
		if err != nil {
			return nil, false, CronError("invalid hour interval value")
		}
		if interval == 0 {
			return nil, false, CronError("step cannot be 0")
		}

		var fromHour, toHour int
		if rangePart == "*" {
			fromHour, toHour = 0, 23
		} else if strings.Contains(rangePart, "-") {
			startStr, endStr, _ := strings.Cut(rangePart, "-")
			s, err := strconv.Atoi(startStr)
			if err != nil {
				return nil, false, CronError("invalid hour range")
			}
			e, err := strconv.Atoi(endStr)
			if err != nil {
				return nil, false, CronError("invalid hour range")
			}
			if s > e {
				return nil, false, CronError(fmt.Sprintf("range start must be <= end: %d-%d", s, e))
			}
			fromHour, toHour = s, e
		} else {
			h, err := strconv.Atoi(rangePart)
			if err != nil {
				return nil, false, CronError("invalid hour value")
			}
			fromHour, toHour = h, 23
		}

		if (domField == "*" || domField == "?") && (dowField == "*" || dowField == "?") {
			// Use :59 only for full day (00:00 to 23:59), otherwise use :00
			var endMinute int
			if fromHour == 0 && toHour == 23 {
				endMinute = 59
			} else {
				endMinute = 0
			}

			schedule := NewScheduleData(NewIntervalRepeat(
				interval,
				IntervalHours,
				TimeOfDay{fromHour, 0},
				TimeOfDay{toHour, endMinute},
				nil,
			))
			schedule.During = during
			return schedule, true, nil
		}
	}

	return nil, false, nil
}

// parseDOMField parses a DOM field into a MonthTarget.
func parseDOMField(field string) (MonthTarget, error) {
	var specs []DayOfMonthSpec

	for _, part := range strings.Split(field, ",") {
		if strings.Contains(part, "/") {
			// Step value: 1-31/2 or */5
			rangePart, stepStr, _ := strings.Cut(part, "/")
			var start, end int
			if rangePart == "*" {
				start, end = 1, 31
			} else if strings.Contains(rangePart, "-") {
				startStr, endStr, _ := strings.Cut(rangePart, "-")
				s, err := strconv.Atoi(startStr)
				if err != nil {
					return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM range start: %s", startStr))
				}
				e, err := strconv.Atoi(endStr)
				if err != nil {
					return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM range end: %s", endStr))
				}
				if s > e {
					return MonthTarget{}, CronError(fmt.Sprintf("range start must be <= end: %d-%d", s, e))
				}
				start, end = s, e
			} else {
				s, err := strconv.Atoi(rangePart)
				if err != nil {
					return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM value: %s", rangePart))
				}
				start, end = s, 31
			}

			step, err := strconv.Atoi(stepStr)
			if err != nil {
				return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM step: %s", stepStr))
			}
			if step == 0 {
				return MonthTarget{}, CronError("step cannot be 0")
			}

			if err := validateDOM(start); err != nil {
				return MonthTarget{}, err
			}
			if err := validateDOM(end); err != nil {
				return MonthTarget{}, err
			}

			for d := start; d <= end; d += step {
				specs = append(specs, NewSingleDay(d))
			}
		} else if strings.Contains(part, "-") {
			// Range: 1-5
			startStr, endStr, _ := strings.Cut(part, "-")
			start, err := strconv.Atoi(startStr)
			if err != nil {
				return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM range start: %s", startStr))
			}
			end, err := strconv.Atoi(endStr)
			if err != nil {
				return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM range end: %s", endStr))
			}
			if start > end {
				return MonthTarget{}, CronError(fmt.Sprintf("range start must be <= end: %d-%d", start, end))
			}
			if err := validateDOM(start); err != nil {
				return MonthTarget{}, err
			}
			if err := validateDOM(end); err != nil {
				return MonthTarget{}, err
			}
			specs = append(specs, NewDayRange(start, end))
		} else {
			// Single: 15
			day, err := strconv.Atoi(part)
			if err != nil {
				return MonthTarget{}, CronError(fmt.Sprintf("invalid DOM value: %s", part))
			}
			if err := validateDOM(day); err != nil {
				return MonthTarget{}, err
			}
			specs = append(specs, NewSingleDay(day))
		}
	}

	return NewDaysTarget(specs), nil
}

func validateDOM(day int) error {
	if day < 1 || day > 31 {
		return CronError(fmt.Sprintf("DOM must be 1-31, got %d", day))
	}
	return nil
}

// parseCronDOW parses a DOW field into a DayFilter.
func parseCronDOW(field string) (DayFilter, error) {
	if field == "*" {
		return NewDayFilterEvery(), nil
	}

	var days []Weekday

	for _, part := range strings.Split(field, ",") {
		if strings.Contains(part, "/") {
			// Step value: 0-6/2 or */2
			rangePart, stepStr, _ := strings.Cut(part, "/")
			var start, end int
			if rangePart == "*" {
				start, end = 0, 6
			} else if strings.Contains(rangePart, "-") {
				startStr, endStr, _ := strings.Cut(rangePart, "-")
				s, err := parseDOWValueRaw(startStr)
				if err != nil {
					return DayFilter{}, err
				}
				e, err := parseDOWValueRaw(endStr)
				if err != nil {
					return DayFilter{}, err
				}
				if s > e {
					return DayFilter{}, CronError(fmt.Sprintf("range start must be <= end: %s-%s", startStr, endStr))
				}
				start, end = s, e
			} else {
				s, err := parseDOWValueRaw(rangePart)
				if err != nil {
					return DayFilter{}, err
				}
				start, end = s, 6
			}

			step, err := strconv.Atoi(stepStr)
			if err != nil {
				return DayFilter{}, CronError(fmt.Sprintf("invalid DOW step: %s", stepStr))
			}
			if step == 0 {
				return DayFilter{}, CronError("step cannot be 0")
			}

			for d := start; d <= end; d += step {
				wd, err := cronDOWToWeekday(d)
				if err != nil {
					return DayFilter{}, err
				}
				days = append(days, wd)
			}
		} else if strings.Contains(part, "-") {
			// Range: 1-5 or MON-FRI
			startStr, endStr, _ := strings.Cut(part, "-")
			// Parse without normalizing 7 to 0 for range purposes
			start, err := parseDOWValueRaw(startStr)
			if err != nil {
				return DayFilter{}, err
			}
			end, err := parseDOWValueRaw(endStr)
			if err != nil {
				return DayFilter{}, err
			}
			if start > end {
				return DayFilter{}, CronError(fmt.Sprintf("range start must be <= end: %s-%s", startStr, endStr))
			}
			for d := start; d <= end; d++ {
				// Normalize 7 to 0 (Sunday) when converting to weekday
				normalized := d
				if d == 7 {
					normalized = 0
				}
				wd, err := cronDOWToWeekday(normalized)
				if err != nil {
					return DayFilter{}, err
				}
				days = append(days, wd)
			}
		} else {
			// Single: 1 or MON
			dow, err := parseDOWValue(part)
			if err != nil {
				return DayFilter{}, err
			}
			wd, err := cronDOWToWeekday(dow)
			if err != nil {
				return DayFilter{}, err
			}
			days = append(days, wd)
		}
	}

	// Check for special patterns
	if len(days) == 5 {
		sorted := make([]Weekday, len(days))
		copy(sorted, days)
		sort.Slice(sorted, func(i, j int) bool {
			return sorted[i].Number() < sorted[j].Number()
		})
		weekdays := []Weekday{Monday, Tuesday, Wednesday, Thursday, Friday}
		if weekdaysEqual(sorted, weekdays) {
			return NewDayFilterWeekday(), nil
		}
	}
	if len(days) == 2 {
		sorted := make([]Weekday, len(days))
		copy(sorted, days)
		sort.Slice(sorted, func(i, j int) bool {
			return sorted[i].Number() < sorted[j].Number()
		})
		weekend := []Weekday{Saturday, Sunday}
		if weekdaysEqual(sorted, weekend) {
			return NewDayFilterWeekend(), nil
		}
	}

	return NewDayFilterDays(days), nil
}

func weekdaysEqual(a, b []Weekday) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// parseDOWValue parses a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0.
func parseDOWValue(s string) (int, error) {
	raw, err := parseDOWValueRaw(s)
	if err != nil {
		return 0, err
	}
	// Normalize 7 to 0 (both mean Sunday)
	if raw == 7 {
		return 0, nil
	}
	return raw, nil
}

// parseDOWValueRaw parses a DOW value without normalizing 7 to 0 (for range checking).
func parseDOWValueRaw(s string) (int, error) {
	// Try as number first
	if n, err := strconv.Atoi(s); err == nil {
		if n > 7 {
			return 0, CronError(fmt.Sprintf("DOW must be 0-7, got %d", n))
		}
		return n, nil
	}
	// Try as name
	switch strings.ToUpper(s) {
	case "SUN":
		return 0, nil
	case "MON":
		return 1, nil
	case "TUE":
		return 2, nil
	case "WED":
		return 3, nil
	case "THU":
		return 4, nil
	case "FRI":
		return 5, nil
	case "SAT":
		return 6, nil
	default:
		return 0, CronError(fmt.Sprintf("invalid DOW: %s", s))
	}
}

var cronDOWMap = map[int]Weekday{
	0: Sunday,
	1: Monday,
	2: Tuesday,
	3: Wednesday,
	4: Thursday,
	5: Friday,
	6: Saturday,
	7: Sunday,
}

func cronDOWToWeekday(n int) (Weekday, error) {
	wd, ok := cronDOWMap[n]
	if !ok {
		return 0, CronError(fmt.Sprintf("invalid DOW number: %d", n))
	}
	return wd, nil
}

// parseSingleValue parses a single numeric value with validation.
func parseSingleValue(field, name string, min, max int) (int, error) {
	value, err := strconv.Atoi(field)
	if err != nil {
		return 0, CronError(fmt.Sprintf("invalid %s field: %s", name, field))
	}
	if value < min || value > max {
		return 0, CronError(fmt.Sprintf("%s must be %d-%d, got %d", name, min, max, value))
	}
	return value, nil
}
