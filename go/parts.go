package hron

import (
	"cmp"
	"fmt"
	"math"
	"slices"
	"strconv"
	"time"
)

const maxInterval = math.MaxInt32

// The checks of spec/README.md, "Schedules built in code", in its order. Each
// list of checks is evaluated in full and cmp.Or returns the first failure, so
// no check may depend on an earlier one passing.
func checkParts(parts *ScheduleData) (*time.Location, error) {
	if err := checkExpr(&parts.Expression); err != nil {
		return nil, err
	}
	for _, exception := range parts.Except {
		if err := checkException(exception); err != nil {
			return nil, err
		}
	}
	if parts.Until != nil {
		if err := checkUntil(*parts.Until); err != nil {
			return nil, err
		}
	}
	if parts.Starting != "" {
		if err := checkISODate(parts.Starting); err != nil {
			return nil, err
		}
	}
	for _, month := range parts.During {
		if err := checkKnown("month", month, Jan, Dec); err != nil {
			return nil, err
		}
	}
	location, canonical, err := resolveTimezone(parts.Timezone)
	if err != nil {
		return nil, err
	}
	parts.Timezone = canonical
	if parts.Until != nil && parts.Until.Kind == UntilSpecKindNamed && parts.Starting == "" {
		return nil, EvalError(noYearMessage(*parts.Until))
	}
	return location, nil
}

func checkExpr(expr *ScheduleExpr) error {
	switch expr.Kind {
	case ScheduleExprKindInterval:
		return cmp.Or(
			checkInterval(expr.Interval),
			checkKnown("interval unit", expr.Unit, IntervalMin, IntervalHours),
			checkWindow(expr.FromTime, expr.ToTime),
			checkOptionalDayFilter(expr.DayFilter),
		)
	case ScheduleExprKindDay:
		return cmp.Or(
			checkInterval(expr.Interval),
			checkEveryDayWhenRepeating(expr.Interval, expr.Days),
			checkDayFilter(expr.Days),
			checkTimes(expr.Times),
		)
	case ScheduleExprKindWeek:
		return cmp.Or(checkInterval(expr.Interval), checkWeekdays(expr.WeekDays), checkTimes(expr.Times))
	case ScheduleExprKindMonth:
		return cmp.Or(checkInterval(expr.Interval), checkMonthTarget(expr.MonthTarget), checkTimes(expr.Times))
	case ScheduleExprKindSingleDate:
		return cmp.Or(checkDateSpec(expr.DateSpec), checkTimes(expr.Times))
	case ScheduleExprKindYear:
		return cmp.Or(checkInterval(expr.Interval), checkYearTarget(expr.YearTarget), checkTimes(expr.Times))
	default:
		return unknown("expression", expr.Kind)
	}
}

func checkInterval(interval int) error {
	if interval < 1 || interval > maxInterval {
		return EvalError(fmt.Sprintf("interval must be 1-%d, got %d", maxInterval, interval))
	}
	return nil
}

// `every 2 days` has no place for a day filter, so other days would not survive display.
func checkEveryDayWhenRepeating(interval int, days DayFilter) error {
	if interval > 1 && days.Kind != DayFilterKindEvery {
		return EvalError("days must be every day when the interval is above 1")
	}
	return nil
}

func checkTimes(times []TimeOfDay) error {
	if len(times) == 0 {
		return EvalError("times must not be empty")
	}
	for _, t := range times {
		if err := checkTime(t); err != nil {
			return err
		}
	}
	return nil
}

func checkTime(t TimeOfDay) error {
	if t.Hour < 0 || t.Hour > 23 || t.Minute < 0 || t.Minute > 59 {
		return EvalError("time must be 00:00-23:59, got " + t.String())
	}
	return nil
}

func checkWindow(from, to TimeOfDay) error {
	backwards := from.TotalMinutes() > to.TotalMinutes()
	if err := cmp.Or(checkTime(from), checkTime(to)); err != nil || !backwards {
		return err
	}
	return EvalError(fmt.Sprintf("time window must not run backwards: %s to %s (a window cannot cross midnight)", from, to))
}

func checkOptionalDayFilter(filter *DayFilter) error {
	if filter == nil {
		return nil
	}
	return checkDayFilter(*filter)
}

func checkDayFilter(filter DayFilter) error {
	switch filter.Kind {
	case DayFilterKindEvery, DayFilterKindWeekday, DayFilterKindWeekend:
		return nil
	case DayFilterKindDays:
		return checkWeekdays(filter.Days)
	default:
		return unknown("day filter", filter.Kind)
	}
}

func checkWeekdays(days []Weekday) error {
	if len(days) == 0 {
		return EvalError("days must not be empty")
	}
	for _, day := range days {
		if err := checkKnown("weekday", day, Monday, Sunday); err != nil {
			return err
		}
	}
	return nil
}

func checkMonthTarget(target MonthTarget) error {
	switch target.Kind {
	case MonthTargetKindDays:
		if len(target.Specs) == 0 {
			return EvalError("days must not be empty")
		}
		for _, spec := range target.Specs {
			if err := checkDayOfMonthSpec(spec); err != nil {
				return err
			}
		}
		return nil
	case MonthTargetKindLastDay, MonthTargetKindLastWeekday:
		return nil
	case MonthTargetKindNearestWeekday:
		return cmp.Or(
			checkKnown("direction", target.Direction, NearestNone, NearestPrevious),
			checkDay(ordinalNumber(target.Day), target.Day),
		)
	case MonthTargetKindOrdinalWeekday:
		return cmp.Or(
			checkKnown("ordinal", target.Ordinal, First, Last),
			checkKnown("weekday", target.Weekday, Monday, Sunday),
		)
	default:
		return unknown("month target", target.Kind)
	}
}

func checkDayOfMonthSpec(spec DayOfMonthSpec) error {
	switch spec.Kind {
	case DayOfMonthSpecKindSingle:
		return checkDay(ordinalNumber(spec.Day), spec.Day)
	case DayOfMonthSpecKindRange:
		err := cmp.Or(checkDay(ordinalNumber(spec.Start), spec.Start), checkDay(ordinalNumber(spec.End), spec.End))
		if err != nil || spec.Start <= spec.End {
			return err
		}
		return EvalError(fmt.Sprintf("day range must not run backwards: %s to %s", ordinalNumber(spec.Start), ordinalNumber(spec.End)))
	default:
		return unknown("day spec", spec.Kind)
	}
}

func checkYearTarget(target YearTarget) error {
	switch target.Kind {
	case YearTargetKindDate:
		return checkNamedDate(target.Month, target.Day)
	case YearTargetKindOrdinalWeekday:
		return cmp.Or(
			checkKnown("ordinal", target.Ordinal, First, Last),
			checkKnown("weekday", target.Weekday, Monday, Sunday),
			checkKnown("month", target.Month, Jan, Dec),
		)
	case YearTargetKindDayOfMonth:
		shown := ordinalNumber(target.Day)
		return cmp.Or(
			checkKnown("month", target.Month, Jan, Dec),
			checkDay(shown, target.Day),
			checkDayInMonth(shown, target.Day, target.Month),
		)
	case YearTargetKindLastWeekday:
		return checkKnown("month", target.Month, Jan, Dec)
	default:
		return unknown("year target", target.Kind)
	}
}

func checkDateSpec(date DateSpec) error {
	switch date.Kind {
	case DateSpecKindNamed:
		return checkNamedDate(date.Month, date.Day)
	case DateSpecKindISO:
		return checkISODate(date.Date)
	default:
		return unknown("date", date.Kind)
	}
}

func checkException(exception ExceptionSpec) error {
	switch exception.Kind {
	case ExceptionSpecKindNamed:
		return checkNamedDate(exception.Month, exception.Day)
	case ExceptionSpecKindISO:
		return checkISODate(exception.Date)
	default:
		return unknown("exception", exception.Kind)
	}
}

func checkUntil(until UntilSpec) error {
	switch until.Kind {
	case UntilSpecKindNamed:
		return checkNamedDate(until.Month, until.Day)
	case UntilSpecKindISO:
		return checkISODate(until.Date)
	default:
		return unknown("until", until.Kind)
	}
}

func checkNamedDate(month MonthName, day int) error {
	shown := strconv.Itoa(day)
	return cmp.Or(
		checkKnown("month", month, Jan, Dec),
		checkDay(shown, day),
		checkDayInMonth(shown, day, month),
	)
}

func checkDay(shown string, day int) error {
	if day < 1 || day > 31 {
		return EvalError("day must be 1-31, got " + shown)
	}
	return nil
}

func checkDayInMonth(shown string, day int, month MonthName) error {
	if day > maxDay(month) {
		return EvalError(fmt.Sprintf("day must be 1-%d for %s, got %s", maxDay(month), month, shown))
	}
	return nil
}

func checkISODate(date string) error {
	if !isCalendarDate(date) {
		return EvalError(invalidDateMessage(date))
	}
	return nil
}

func checkKnown[T ~int](kind string, value, first, last T) error {
	if value < first || value > last {
		return unknown(kind, value)
	}
	return nil
}

func unknown[T ~int](kind string, value T) error {
	return EvalError(fmt.Sprintf("unknown %s %d", kind, value))
}

// The copy keeps only the fields its kinds use, so that equal schedules have
// equal parts, and shares no slice or pointer with the original.
func copyParts(parts *ScheduleData) *ScheduleData {
	out := &ScheduleData{
		Expression: copyExpr(parts.Expression),
		Timezone:   parts.Timezone,
		Starting:   parts.Starting,
	}
	for _, exception := range parts.Except {
		out.Except = append(out.Except, copyException(exception))
	}
	if parts.Until != nil {
		until := copyUntil(*parts.Until)
		out.Until = &until
	}
	if len(parts.During) > 0 {
		out.During = slices.Clone(parts.During)
	}
	return out
}

func copyExpr(expr ScheduleExpr) ScheduleExpr {
	out := ScheduleExpr{Kind: expr.Kind}
	switch expr.Kind {
	case ScheduleExprKindInterval:
		out.Interval, out.Unit, out.FromTime, out.ToTime = expr.Interval, expr.Unit, expr.FromTime, expr.ToTime
		if expr.DayFilter != nil {
			filter := copyDayFilter(*expr.DayFilter)
			out.DayFilter = &filter
		}
		return out
	case ScheduleExprKindDay:
		out.Interval, out.Days = expr.Interval, copyDayFilter(expr.Days)
	case ScheduleExprKindWeek:
		out.Interval, out.WeekDays = expr.Interval, slices.Clone(expr.WeekDays)
	case ScheduleExprKindMonth:
		out.Interval, out.MonthTarget = expr.Interval, copyMonthTarget(expr.MonthTarget)
	case ScheduleExprKindSingleDate:
		out.DateSpec = copyDateSpec(expr.DateSpec)
	case ScheduleExprKindYear:
		out.Interval, out.YearTarget = expr.Interval, copyYearTarget(expr.YearTarget)
	default:
		return out
	}
	out.Times = slices.Clone(expr.Times)
	return out
}

func copyDayFilter(filter DayFilter) DayFilter {
	if filter.Kind == DayFilterKindDays {
		return DayFilter{Kind: filter.Kind, Days: slices.Clone(filter.Days)}
	}
	return DayFilter{Kind: filter.Kind}
}

func copyMonthTarget(target MonthTarget) MonthTarget {
	out := MonthTarget{Kind: target.Kind}
	switch target.Kind {
	case MonthTargetKindDays:
		out.Specs = make([]DayOfMonthSpec, len(target.Specs))
		for i, spec := range target.Specs {
			out.Specs[i] = copyDayOfMonthSpec(spec)
		}
	case MonthTargetKindNearestWeekday:
		out.Day, out.Direction = target.Day, target.Direction
	case MonthTargetKindOrdinalWeekday:
		out.Ordinal, out.Weekday = target.Ordinal, target.Weekday
	}
	return out
}

func copyDayOfMonthSpec(spec DayOfMonthSpec) DayOfMonthSpec {
	switch spec.Kind {
	case DayOfMonthSpecKindSingle:
		return DayOfMonthSpec{Kind: spec.Kind, Day: spec.Day}
	case DayOfMonthSpecKindRange:
		return DayOfMonthSpec{Kind: spec.Kind, Start: spec.Start, End: spec.End}
	default:
		return DayOfMonthSpec{Kind: spec.Kind}
	}
}

func copyYearTarget(target YearTarget) YearTarget {
	switch target.Kind {
	case YearTargetKindDate, YearTargetKindDayOfMonth:
		return YearTarget{Kind: target.Kind, Month: target.Month, Day: target.Day}
	case YearTargetKindOrdinalWeekday:
		return YearTarget{Kind: target.Kind, Month: target.Month, Ordinal: target.Ordinal, Weekday: target.Weekday}
	case YearTargetKindLastWeekday:
		return YearTarget{Kind: target.Kind, Month: target.Month}
	default:
		return YearTarget{Kind: target.Kind}
	}
}

func copyDateSpec(date DateSpec) DateSpec {
	switch date.Kind {
	case DateSpecKindNamed:
		return DateSpec{Kind: date.Kind, Month: date.Month, Day: date.Day}
	case DateSpecKindISO:
		return DateSpec{Kind: date.Kind, Date: date.Date}
	default:
		return DateSpec{Kind: date.Kind}
	}
}

func copyException(exception ExceptionSpec) ExceptionSpec {
	switch exception.Kind {
	case ExceptionSpecKindNamed:
		return ExceptionSpec{Kind: exception.Kind, Month: exception.Month, Day: exception.Day}
	case ExceptionSpecKindISO:
		return ExceptionSpec{Kind: exception.Kind, Date: exception.Date}
	default:
		return ExceptionSpec{Kind: exception.Kind}
	}
}

func copyUntil(until UntilSpec) UntilSpec {
	switch until.Kind {
	case UntilSpecKindNamed:
		return UntilSpec{Kind: until.Kind, Month: until.Month, Day: until.Day}
	case UntilSpecKindISO:
		return UntilSpec{Kind: until.Kind, Date: until.Date}
	default:
		return UntilSpec{Kind: until.Kind}
	}
}
