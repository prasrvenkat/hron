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
	fields := strings.Fields(strings.TrimSpace(cron))
	if len(fields) != 5 {
		return nil, CronError(fmt.Sprintf("expected 5 cron fields, got %d", len(fields)))
	}

	minuteField := fields[0]
	hourField := fields[1]
	domField := fields[2]
	// monthField := fields[3]  // not used
	dowField := fields[4]

	// Minute interval: */N
	if strings.HasPrefix(minuteField, "*/") {
		intervalStr := minuteField[2:]
		interval, err := strconv.Atoi(intervalStr)
		if err != nil {
			return nil, CronError("invalid minute interval")
		}

		fromHour := 0
		toHour := 23

		if hourField == "*" {
			// full day
		} else if strings.Contains(hourField, "-") {
			parts := strings.Split(hourField, "-")
			if len(parts) != 2 {
				return nil, CronError("invalid hour range")
			}
			fromHour, err = strconv.Atoi(parts[0])
			if err != nil {
				return nil, CronError("invalid hour range")
			}
			toHour, err = strconv.Atoi(parts[1])
			if err != nil {
				return nil, CronError("invalid hour range")
			}
		} else {
			h, err := strconv.Atoi(hourField)
			if err != nil {
				return nil, CronError("invalid hour")
			}
			fromHour = h
			toHour = h
		}

		var dayFilter *DayFilter
		if dowField != "*" {
			df, err := parseCronDOW(dowField)
			if err != nil {
				return nil, err
			}
			dayFilter = &df
		}

		if domField == "*" {
			toMin := 59
			if toHour != 23 {
				toMin = 0
			}
			return NewScheduleData(NewIntervalRepeat(
				interval,
				IntervalMin,
				TimeOfDay{fromHour, 0},
				TimeOfDay{toHour, toMin},
				dayFilter,
			)), nil
		}
	}

	// Hour interval: 0 */N
	if strings.HasPrefix(hourField, "*/") && minuteField == "0" {
		intervalStr := hourField[2:]
		interval, err := strconv.Atoi(intervalStr)
		if err != nil {
			return nil, CronError("invalid hour interval")
		}
		if domField == "*" && dowField == "*" {
			return NewScheduleData(NewIntervalRepeat(
				interval,
				IntervalHours,
				TimeOfDay{0, 0},
				TimeOfDay{23, 59},
				nil,
			)), nil
		}
	}

	// Standard time-based cron
	minute, err := strconv.Atoi(minuteField)
	if err != nil {
		return nil, CronError(fmt.Sprintf("invalid minute field: %s", minuteField))
	}
	hour, err := strconv.Atoi(hourField)
	if err != nil {
		return nil, CronError(fmt.Sprintf("invalid hour field: %s", hourField))
	}
	t := TimeOfDay{hour, minute}

	// DOM-based (monthly)
	if domField != "*" && dowField == "*" {
		if strings.Contains(domField, "-") {
			return nil, CronError(fmt.Sprintf("DOM ranges not supported: %s", domField))
		}
		var dayNums []int
		for _, s := range strings.Split(domField, ",") {
			n, err := strconv.Atoi(s)
			if err != nil {
				return nil, CronError(fmt.Sprintf("invalid DOM field: %s", domField))
			}
			dayNums = append(dayNums, n)
		}
		specs := make([]DayOfMonthSpec, len(dayNums))
		for i, d := range dayNums {
			specs[i] = NewSingleDay(d)
		}
		return NewScheduleData(NewMonthRepeat(1, NewDaysTarget(specs), []TimeOfDay{t})), nil
	}

	// DOW-based (day repeat)
	days, err := parseCronDOW(dowField)
	if err != nil {
		return nil, err
	}
	return NewScheduleData(NewDayRepeat(1, days, []TimeOfDay{t})), nil
}

func parseCronDOW(field string) (DayFilter, error) {
	if field == "*" {
		return NewDayFilterEvery(), nil
	}
	if field == "1-5" {
		return NewDayFilterWeekday(), nil
	}
	if field == "0,6" || field == "6,0" {
		return NewDayFilterWeekend(), nil
	}

	if strings.Contains(field, "-") {
		return DayFilter{}, CronError(fmt.Sprintf("DOW ranges not supported: %s", field))
	}

	var nums []int
	for _, s := range strings.Split(field, ",") {
		n, err := strconv.Atoi(s)
		if err != nil {
			return DayFilter{}, CronError(fmt.Sprintf("invalid DOW field: %s", field))
		}
		nums = append(nums, n)
	}

	days := make([]Weekday, len(nums))
	for i, n := range nums {
		wd, err := cronDOWToWeekday(n)
		if err != nil {
			return DayFilter{}, err
		}
		days[i] = wd
	}
	return NewDayFilterDays(days), nil
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
