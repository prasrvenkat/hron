package hron

import (
	"fmt"
	"strings"
)

// Display renders the schedule as a canonical string.
func Display(schedule *ScheduleData) string {
	var sb strings.Builder

	sb.WriteString(displayExpr(schedule.Expr))

	if len(schedule.Except) > 0 {
		sb.WriteString(" except ")
		sb.WriteString(displayExceptions(schedule.Except))
	}

	if schedule.Until != nil {
		sb.WriteString(" until ")
		sb.WriteString(displayUntil(*schedule.Until))
	}

	if schedule.Anchor != "" {
		sb.WriteString(" starting ")
		sb.WriteString(schedule.Anchor)
	}

	if len(schedule.During) > 0 {
		sb.WriteString(" during ")
		sb.WriteString(displayMonthList(schedule.During))
	}

	if schedule.Timezone != "" {
		sb.WriteString(" in ")
		sb.WriteString(schedule.Timezone)
	}

	return sb.String()
}

func displayExpr(expr ScheduleExpr) string {
	switch expr.Kind {
	case ScheduleExprKindInterval:
		return displayIntervalRepeat(expr)
	case ScheduleExprKindDay:
		return displayDayRepeat(expr)
	case ScheduleExprKindWeek:
		return displayWeekRepeat(expr)
	case ScheduleExprKindMonth:
		return displayMonthRepeat(expr)
	case ScheduleExprKindOrdinal:
		return displayOrdinalRepeat(expr)
	case ScheduleExprKindSingleDate:
		return displaySingleDate(expr)
	case ScheduleExprKindYear:
		return displayYearRepeat(expr)
	default:
		return ""
	}
}

func displayIntervalRepeat(expr ScheduleExpr) string {
	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("every %d %s", expr.Interval, unitDisplay(expr.Interval, expr.Unit)))
	sb.WriteString(fmt.Sprintf(" from %s to %s", expr.FromTime.String(), expr.ToTime.String()))
	if expr.DayFilter != nil {
		sb.WriteString(" on ")
		sb.WriteString(displayDayFilter(*expr.DayFilter))
	}
	return sb.String()
}

func displayDayRepeat(expr ScheduleExpr) string {
	if expr.Interval > 1 {
		return fmt.Sprintf("every %d days at %s", expr.Interval, formatTimeList(expr.Times))
	}
	return fmt.Sprintf("every %s at %s", displayDayFilter(expr.Days), formatTimeList(expr.Times))
}

func displayWeekRepeat(expr ScheduleExpr) string {
	dayStr := formatDayList(expr.WeekDays)
	return fmt.Sprintf("every %d weeks on %s at %s", expr.Interval, dayStr, formatTimeList(expr.Times))
}

func displayMonthRepeat(expr ScheduleExpr) string {
	targetStr := displayMonthTarget(expr.MonthTarget)
	if expr.Interval > 1 {
		return fmt.Sprintf("every %d months on the %s at %s", expr.Interval, targetStr, formatTimeList(expr.Times))
	}
	return fmt.Sprintf("every month on the %s at %s", targetStr, formatTimeList(expr.Times))
}

func displayOrdinalRepeat(expr ScheduleExpr) string {
	if expr.Interval > 1 {
		return fmt.Sprintf("%s %s of every %d months at %s",
			expr.Ordinal.String(), expr.OrdinalDay.String(), expr.Interval, formatTimeList(expr.Times))
	}
	return fmt.Sprintf("%s %s of every month at %s",
		expr.Ordinal.String(), expr.OrdinalDay.String(), formatTimeList(expr.Times))
}

func displaySingleDate(expr ScheduleExpr) string {
	dateStr := displayDateSpec(expr.DateSpec)
	return fmt.Sprintf("on %s at %s", dateStr, formatTimeList(expr.Times))
}

func displayYearRepeat(expr ScheduleExpr) string {
	targetStr := displayYearTarget(expr.YearTarget)
	if expr.Interval > 1 {
		return fmt.Sprintf("every %d years on %s at %s", expr.Interval, targetStr, formatTimeList(expr.Times))
	}
	return fmt.Sprintf("every year on %s at %s", targetStr, formatTimeList(expr.Times))
}

func displayDayFilter(f DayFilter) string {
	switch f.Kind {
	case DayFilterKindEvery:
		return "day"
	case DayFilterKindWeekday:
		return "weekday"
	case DayFilterKindWeekend:
		return "weekend"
	case DayFilterKindDays:
		return formatDayList(f.Days)
	default:
		return ""
	}
}

func displayMonthTarget(target MonthTarget) string {
	switch target.Kind {
	case MonthTargetKindLastDay:
		return "last day"
	case MonthTargetKindLastWeekday:
		return "last weekday"
	case MonthTargetKindDays:
		return formatOrdinalDaySpecs(target.Specs)
	case MonthTargetKindNearestWeekday:
		var sb strings.Builder
		switch target.Direction {
		case NearestNext:
			sb.WriteString("next ")
		case NearestPrevious:
			sb.WriteString("previous ")
		}
		sb.WriteString(fmt.Sprintf("nearest weekday to %s", ordinalNumber(target.Day)))
		return sb.String()
	default:
		return ""
	}
}

func displayYearTarget(target YearTarget) string {
	switch target.Kind {
	case YearTargetKindDate:
		return fmt.Sprintf("%s %d", target.Month.String(), target.Day)
	case YearTargetKindOrdinalWeekday:
		return fmt.Sprintf("the %s %s of %s", target.Ordinal.String(), target.Weekday.String(), target.Month.String())
	case YearTargetKindDayOfMonth:
		return fmt.Sprintf("the %s of %s", ordinalNumber(target.Day), target.Month.String())
	case YearTargetKindLastWeekday:
		return fmt.Sprintf("the last weekday of %s", target.Month.String())
	default:
		return ""
	}
}

func displayDateSpec(spec DateSpec) string {
	switch spec.Kind {
	case DateSpecKindNamed:
		return fmt.Sprintf("%s %d", spec.Month.String(), spec.Day)
	case DateSpecKindISO:
		return spec.Date
	default:
		return ""
	}
}

func displayExceptions(exceptions []ExceptionSpec) string {
	parts := make([]string, len(exceptions))
	for i, exc := range exceptions {
		switch exc.Kind {
		case ExceptionSpecKindNamed:
			parts[i] = fmt.Sprintf("%s %d", exc.Month.String(), exc.Day)
		case ExceptionSpecKindISO:
			parts[i] = exc.Date
		}
	}
	return strings.Join(parts, ", ")
}

func displayUntil(until UntilSpec) string {
	switch until.Kind {
	case UntilSpecKindISO:
		return until.Date
	case UntilSpecKindNamed:
		return fmt.Sprintf("%s %d", until.Month.String(), until.Day)
	default:
		return ""
	}
}

func displayMonthList(months []MonthName) string {
	parts := make([]string, len(months))
	for i, m := range months {
		parts[i] = m.String()
	}
	return strings.Join(parts, ", ")
}

func formatTimeList(times []TimeOfDay) string {
	parts := make([]string, len(times))
	for i, t := range times {
		parts[i] = t.String()
	}
	return strings.Join(parts, ", ")
}

func formatDayList(days []Weekday) string {
	parts := make([]string, len(days))
	for i, d := range days {
		parts[i] = d.String()
	}
	return strings.Join(parts, ", ")
}

func formatOrdinalDaySpecs(specs []DayOfMonthSpec) string {
	parts := make([]string, len(specs))
	for i, spec := range specs {
		switch spec.Kind {
		case DayOfMonthSpecKindSingle:
			parts[i] = ordinalNumber(spec.Day)
		case DayOfMonthSpecKindRange:
			parts[i] = fmt.Sprintf("%s to %s", ordinalNumber(spec.Start), ordinalNumber(spec.End))
		}
	}
	return strings.Join(parts, ", ")
}

func ordinalNumber(n int) string {
	return fmt.Sprintf("%d%s", n, ordinalSuffix(n))
}

func ordinalSuffix(n int) string {
	mod100 := n % 100
	if mod100 >= 11 && mod100 <= 13 {
		return "th"
	}
	switch n % 10 {
	case 1:
		return "st"
	case 2:
		return "nd"
	case 3:
		return "rd"
	default:
		return "th"
	}
}

func unitDisplay(interval int, unit IntervalUnit) string {
	if unit == IntervalMin {
		if interval == 1 {
			return "minute"
		}
		return "min"
	}
	if interval == 1 {
		return "hour"
	}
	return "hours"
}
