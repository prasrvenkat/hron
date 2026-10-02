package hron

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
)

const (
	maxListedTimes     = 24
	bothDaysRestricted = "not expressible in hron: cron fires on either the day of month or the day of week"
	intervalDays       = "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days"
)

var (
	midnight = TimeOfDay{Hour: 0, Minute: 0}
	endOfDay = TimeOfDay{Hour: 23, Minute: 59}
)

// Digit strings may be of any length. Every number at or above this cap is out
// of every field's range and steps past every range's end, so saturating at it
// keeps each comparison exact without overflow.
const numberCap = 1000

var (
	monthNames   = []string{"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	dayNames     = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
	cronWeekdays = [7]Weekday{Sunday, Monday, Tuesday, Wednesday, Thursday, Friday, Saturday}
)

type cronField int

const (
	minuteField cronField = iota
	hourField
	dayOfMonthField
	monthField
	dayOfWeekField
)

func (f cronField) name() string {
	switch f {
	case minuteField:
		return "minute"
	case hourField:
		return "hour"
	case dayOfMonthField:
		return "day of month"
	case monthField:
		return "month"
	default:
		return "day of week"
	}
}

func (f cronField) min() int {
	if f == dayOfMonthField || f == monthField {
		return 1
	}
	return 0
}

func (f cronField) max() int {
	switch f {
	case minuteField:
		return 59
	case hourField:
		return 23
	case dayOfMonthField:
		return 31
	case monthField:
		return 12
	default:
		return 7
	}
}

// In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
func (f cronField) starEnd() int {
	if f == dayOfWeekField {
		return 6
	}
	return f.max()
}

func (f cronField) names() []string {
	switch f {
	case monthField:
		return monthNames
	case dayOfWeekField:
		return dayNames
	default:
		return nil
	}
}

type boundsKind int

const (
	starBounds boundsKind = iota
	valueBounds
	rangeBounds
)

type cronItem struct {
	kind    boundsKind
	a, b    string
	step    string
	hasStep bool
}

type monthDaysKind int

const (
	anyMonthDay monthDaysKind = iota
	listedMonthDays
	lastMonthDay
	lastMonthWeekday
	nearestMonthWeekday
)

type monthDays struct {
	kind    monthDaysKind
	days    []int
	nearest int
}

type weekDaysKind int

const (
	anyWeekDay weekDaysKind = iota
	listedWeekDays
	ordinalWeekDay
)

type weekDays struct {
	kind    weekDaysKind
	days    []int
	ordinal OrdinalPosition
	weekday Weekday
}

type cronDays struct {
	ofMonth bool
	filter  DayFilter
	target  MonthTarget
}

func fromCron(input string) (*ScheduleData, error) {
	input = strings.Trim(input, " \t\r\n")
	text := input
	if strings.HasPrefix(input, "@") {
		var err error
		if text, err = shortcut(input); err != nil {
			return nil, err
		}
	}
	fields := strings.FieldsFunc(text, func(r rune) bool { return r == ' ' || r == '\t' })
	if len(fields) != 5 {
		return nil, CronError(fmt.Sprintf("expected 5 cron fields, got %d", len(fields)))
	}

	minuteValues, err := values(fields[0], minuteField)
	if err != nil {
		return nil, err
	}
	hourValues, err := values(fields[1], hourField)
	if err != nil {
		return nil, err
	}
	monthDayValues, err := parseDayOfMonth(fields[2])
	if err != nil {
		return nil, err
	}
	monthValues, err := values(fields[3], monthField)
	if err != nil {
		return nil, err
	}
	weekDayValues, err := parseDayOfWeek(fields[4])
	if err != nil {
		return nil, err
	}
	days, err := dayExpression(monthDayValues, weekDayValues)
	if err != nil {
		return nil, err
	}
	minutes, hours, months := sorted(minuteValues), sorted(hourValues), sorted(monthValues)
	times := make([]TimeOfDay, 0, len(hours)*len(minutes))
	for _, hour := range hours {
		for _, minute := range minutes {
			times = append(times, TimeOfDay{Hour: hour, Minute: minute})
		}
	}

	gap, equal := equalGap(times)
	target, yearly := yearTarget(days, months)
	var expr ScheduleExpr
	switch {
	case !days.ofMonth && equal:
		expr = interval(times, gap, days.filter)
	case len(times) > maxListedTimes:
		return nil, tooManyTimes(len(times), equal)
	case yearly:
		expr = NewYearRepeat(1, target, times)
	case days.ofMonth:
		expr = NewMonthRepeat(1, days.target, times)
	default:
		expr = NewDayRepeat(1, days.filter, times)
	}
	schedule := NewScheduleData(expr)
	if expr.Kind != ScheduleExprKindYear && len(months) < 12 {
		for _, m := range months {
			schedule.During = append(schedule.During, MonthName(m))
		}
	}
	return schedule, nil
}

func shortcut(input string) (string, error) {
	switch asciiLower(input) {
	case "@yearly", "@annually":
		return "0 0 1 1 *", nil
	case "@monthly":
		return "0 0 1 * *", nil
	case "@weekly":
		return "0 0 * * 0", nil
	case "@daily", "@midnight":
		return "0 0 * * *", nil
	case "@hourly":
		return "0 * * * *", nil
	default:
		return "", CronError(fmt.Sprintf("unknown cron shortcut: %s", input))
	}
}

func parseDayOfMonth(text string) (monthDays, error) {
	if text == "*" || text == "?" {
		return monthDays{kind: anyMonthDay}, nil
	}
	switch asciiLower(text) {
	case "l":
		return monthDays{kind: lastMonthDay}, nil
	case "lw":
		return monthDays{kind: lastMonthWeekday}, nil
	}
	if day, ok := cutSuffixFold(text, "w"); ok && isNumber(day) {
		value, err := fieldValue(day, dayOfMonthField)
		if err != nil {
			return monthDays{}, err
		}
		return monthDays{kind: nearestMonthWeekday, nearest: value}, nil
	}
	days, err := values(text, dayOfMonthField)
	if err != nil {
		return monthDays{}, err
	}
	return monthDays{kind: listedMonthDays, days: days}, nil
}

func parseDayOfWeek(text string) (weekDays, error) {
	field := dayOfWeekField
	if text == "*" || text == "?" {
		return weekDays{kind: anyWeekDay}, nil
	}
	if day, nth, found := strings.Cut(text, "#"); found && isValue(day, field) && isNumber(nth) {
		value, err := fieldValue(day, field)
		if err != nil {
			return weekDays{}, err
		}
		n := number(nth)
		if n < 1 || n > 5 {
			return weekDays{}, CronError(fmt.Sprintf("day of week ordinal must be 1-5, got %s", nth))
		}
		return weekDays{kind: ordinalWeekDay, ordinal: OrdinalPosition(n), weekday: cronWeekdays[value%7]}, nil
	}
	if day, ok := cutSuffixFold(text, "l"); ok && isValue(day, field) {
		value, err := fieldValue(day, field)
		if err != nil {
			return weekDays{}, err
		}
		return weekDays{kind: ordinalWeekDay, ordinal: Last, weekday: cronWeekdays[value%7]}, nil
	}
	days, err := values(text, field)
	if err != nil {
		return weekDays{}, err
	}
	return weekDays{kind: listedWeekDays, days: days}, nil
}

// Keeps the order of first appearance, in which fromCron lists days of the week.
func values(text string, field cronField) ([]int, error) {
	items, ok := parseItems(text, field)
	if !ok {
		return nil, CronError(fmt.Sprintf("invalid %s: %s", field.name(), text))
	}
	var values []int
	for _, item := range items {
		var first, last int
		switch item.kind {
		case starBounds:
			first, last = field.min(), field.starEnd()
		case valueBounds:
			value, err := fieldValue(item.a, field)
			if err != nil {
				return nil, err
			}
			first, last = value, value
			if item.hasStep {
				// `7/n` starts past the end of `*`, so it is Sunday alone.
				last = max(first, field.starEnd())
			}
		case rangeBounds:
			a, err := fieldValue(item.a, field)
			if err != nil {
				return nil, err
			}
			b, err := fieldValue(item.b, field)
			if err != nil {
				return nil, err
			}
			if a > b {
				return nil, CronError(fmt.Sprintf("%s range must not run backwards: %s-%s", field.name(), item.a, item.b))
			}
			first, last = a, b
		}
		step := 1
		if item.hasStep {
			step = number(item.step)
		}
		if step == 0 {
			return nil, CronError(fmt.Sprintf("%s step must be at least 1", field.name()))
		}
		for n := first; n <= last; n += step {
			value := n
			if field == dayOfWeekField {
				value %= 7
			}
			if !slices.Contains(values, value) {
				values = append(values, value)
			}
		}
	}
	return values, nil
}

func parseItems(text string, field cronField) ([]cronItem, bool) {
	parts := strings.Split(text, ",")
	items := make([]cronItem, 0, len(parts))
	for _, part := range parts {
		var item cronItem
		var bounds string
		bounds, item.step, item.hasStep = strings.Cut(part, "/")
		a, b, isRange := strings.Cut(bounds, "-")
		switch {
		case bounds == "*":
			item.kind = starBounds
		case isRange:
			item.kind, item.a, item.b = rangeBounds, a, b
		default:
			item.kind, item.a = valueBounds, bounds
		}
		valid := !item.hasStep || isNumber(item.step)
		switch item.kind {
		case valueBounds:
			valid = valid && isValue(item.a, field)
		case rangeBounds:
			valid = valid && isValue(item.a, field) && isValue(item.b, field)
		}
		if !valid {
			return nil, false
		}
		items = append(items, item)
	}
	return items, true
}

func isNumber(text string) bool {
	if text == "" {
		return false
	}
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	return true
}

func isValue(text string, field cronField) bool {
	_, named := nameValue(text, field)
	return isNumber(text) || named
}

func nameValue(text string, field cronField) (int, bool) {
	index := slices.Index(field.names(), asciiLower(text))
	return index + field.min(), index >= 0
}

func number(digits string) int {
	n := 0
	for i := 0; i < len(digits); i++ {
		n = min(n*10+int(digits[i]-'0'), numberCap)
	}
	return n
}

func fieldValue(text string, field cronField) (int, error) {
	value, named := nameValue(text, field)
	if !named {
		value = number(text)
	}
	if value < field.min() || value > field.max() {
		return 0, CronError(fmt.Sprintf("%s must be %d-%d, got %s", field.name(), field.min(), field.max(), text))
	}
	return value, nil
}

// Folds ASCII letters only: Unicode folding would let `ſ` match `s` and `K` match `k`.
func asciiLower(text string) string {
	lower := []byte(text)
	for i, c := range lower {
		if 'A' <= c && c <= 'Z' {
			lower[i] = c + 'a' - 'A'
		}
	}
	return string(lower)
}

func cutSuffixFold(text, lowerSuffix string) (string, bool) {
	if strings.HasSuffix(asciiLower(text), lowerSuffix) {
		return text[:len(text)-len(lowerSuffix)], true
	}
	return text, false
}

func dayExpression(month monthDays, week weekDays) (cronDays, error) {
	switch {
	case month.kind == anyMonthDay && week.kind == anyWeekDay:
		return cronDays{filter: NewDayFilterEvery()}, nil
	case month.kind == anyMonthDay && week.kind == listedWeekDays:
		return cronDays{filter: weekdayFilter(week.days)}, nil
	case month.kind == anyMonthDay:
		return cronDays{ofMonth: true, target: NewOrdinalWeekdayTarget(week.ordinal, week.weekday)}, nil
	case week.kind != anyWeekDay:
		return cronDays{}, CronError(bothDaysRestricted)
	case month.kind == listedMonthDays && len(month.days) == 31:
		return cronDays{filter: NewDayFilterEvery()}, nil
	case month.kind == listedMonthDays:
		var specs []DayOfMonthSpec
		for _, run := range runs(sorted(month.days)) {
			if run[0] == run[1] {
				specs = append(specs, NewSingleDay(run[0]))
			} else {
				specs = append(specs, NewDayRange(run[0], run[1]))
			}
		}
		return cronDays{ofMonth: true, target: NewDaysTarget(specs)}, nil
	case month.kind == lastMonthDay:
		return cronDays{ofMonth: true, target: NewLastDayTarget()}, nil
	case month.kind == lastMonthWeekday:
		return cronDays{ofMonth: true, target: NewLastWeekdayTarget()}, nil
	default:
		return cronDays{ofMonth: true, target: NewNearestWeekdayTarget(month.nearest, NearestNone)}, nil
	}
}

func weekdayFilter(days []int) DayFilter {
	ascending := sorted(days)
	switch {
	case slices.Equal(ascending, []int{0, 1, 2, 3, 4, 5, 6}):
		return NewDayFilterEvery()
	case slices.Equal(ascending, []int{1, 2, 3, 4, 5}):
		return NewDayFilterWeekday()
	case slices.Equal(ascending, []int{0, 6}):
		return NewDayFilterWeekend()
	}
	weekdays := make([]Weekday, len(days))
	for i, d := range days {
		weekdays[i] = cronWeekdays[d]
	}
	return NewDayFilterDays(weekdays)
}

func equalGap(times []TimeOfDay) (int, bool) {
	if len(times) < 3 {
		return 0, false
	}
	gap := times[1].TotalMinutes() - times[0].TotalMinutes()
	for i := 2; i < len(times); i++ {
		if times[i].TotalMinutes()-times[i-1].TotalMinutes() != gap {
			return 0, false
		}
	}
	return gap, true
}

func interval(times []TimeOfDay, gap int, days DayFilter) ScheduleExpr {
	from, to := times[0], times[len(times)-1]
	if from == midnight && to.TotalMinutes()+gap >= minutesPerDay {
		to = endOfDay
	}
	var dayFilter *DayFilter
	if days.Kind != DayFilterKindEvery {
		dayFilter = &days
	}
	if gap%60 == 0 {
		return NewIntervalRepeat(gap/60, IntervalHours, from, to, dayFilter)
	}
	return NewIntervalRepeat(gap, IntervalMin, from, to, dayFilter)
}

func tooManyTimes(count int, equalGaps bool) error {
	if equalGaps {
		return CronError(intervalDays)
	}
	return CronError(fmt.Sprintf("not expressible in hron: %d times a day are too many to list", count))
}

func yearTarget(days cronDays, months []int) (YearTarget, bool) {
	if !days.ofMonth || len(months) != 1 {
		return YearTarget{}, false
	}
	month := MonthName(months[0])
	target := days.target
	switch target.Kind {
	case MonthTargetKindDays:
		if len(target.Specs) == 1 && target.Specs[0].Kind == DayOfMonthSpecKindSingle && target.Specs[0].Day <= maxDay(month) {
			return NewYearDateTarget(month, target.Specs[0].Day), true
		}
	case MonthTargetKindLastWeekday:
		return NewYearLastWeekdayTarget(month), true
	case MonthTargetKindOrdinalWeekday:
		return NewYearOrdinalWeekdayTarget(target.Ordinal, target.Weekday, month), true
	}
	return YearTarget{}, false
}

func maxDay(month MonthName) int {
	switch month {
	case Feb:
		return 29
	case Apr, Jun, Sep, Nov:
		return 30
	default:
		return 31
	}
}

func toCron(schedule *ScheduleData) (string, error) {
	if len(schedule.Except) > 0 {
		return "", notExpressible("except clauses not supported")
	}
	if schedule.Until != nil {
		return "", notExpressible("until clauses not supported")
	}
	if schedule.Starting != "" {
		return "", notExpressible("starting clauses not supported")
	}
	dayOfMonth, dayOfWeek, err := dayFields(&schedule.Expression)
	if err != nil {
		return "", err
	}
	month, err := monthFieldOf(schedule)
	if err != nil {
		return "", err
	}
	minute, hour, err := timeFields(&schedule.Expression)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s %s %s %s %s", minute, hour, dayOfMonth, month, dayOfWeek), nil
}

func notExpressible(reason string) error {
	return CronError("not expressible as cron: " + reason)
}

func repeatsOnce(interval int, unit string) error {
	if interval > 1 {
		return notExpressible(fmt.Sprintf("multi-%s repeats not supported", unit))
	}
	return nil
}

func dayFields(expr *ScheduleExpr) (string, string, error) {
	switch expr.Kind {
	case ScheduleExprKindInterval:
		if expr.DayFilter == nil {
			return "*", "*", nil
		}
		return "*", filterField(*expr.DayFilter), nil
	case ScheduleExprKindDay:
		if err := repeatsOnce(expr.Interval, "day"); err != nil {
			return "", "", err
		}
		return "*", filterField(expr.Days), nil
	case ScheduleExprKindWeek:
		if err := repeatsOnce(expr.Interval, "week"); err != nil {
			return "", "", err
		}
		return "*", weekdaysField(expr.WeekDays), nil
	case ScheduleExprKindMonth:
		if err := repeatsOnce(expr.Interval, "month"); err != nil {
			return "", "", err
		}
		target := expr.MonthTarget
		switch target.Kind {
		case MonthTargetKindDays:
			return listField(sortedUnique(target.ExpandDays()), 31), "*", nil
		case MonthTargetKindLastDay:
			return "L", "*", nil
		case MonthTargetKindLastWeekday:
			return "LW", "*", nil
		case MonthTargetKindNearestWeekday:
			if target.Direction != NearestNone {
				return "", "", notExpressible("directional nearest weekday not supported")
			}
			return fmt.Sprintf("%dW", target.Day), "*", nil
		case MonthTargetKindOrdinalWeekday:
			return "*", ordinalField(target.Ordinal, target.Weekday), nil
		}
	case ScheduleExprKindYear:
		if err := repeatsOnce(expr.Interval, "year"); err != nil {
			return "", "", err
		}
		target := expr.YearTarget
		switch target.Kind {
		case YearTargetKindDate, YearTargetKindDayOfMonth:
			return strconv.Itoa(target.Day), "*", nil
		case YearTargetKindOrdinalWeekday:
			return "*", ordinalField(target.Ordinal, target.Weekday), nil
		case YearTargetKindLastWeekday:
			return "LW", "*", nil
		}
	case ScheduleExprKindSingleDate:
		if expr.DateSpec.Kind == DateSpecKindISO {
			return "", "", notExpressible("ISO dates do not repeat")
		}
		return strconv.Itoa(expr.DateSpec.Day), "*", nil
	}
	panic(fmt.Sprintf("unknown expression or target kind: %+v", *expr))
}

func monthFieldOf(schedule *ScheduleData) (string, error) {
	during := schedule.During
	month, ok := ownMonth(&schedule.Expression)
	switch {
	case ok && len(during) > 0 && !slices.Contains(during, month):
		return "", notExpressible("during excludes the schedule's month")
	case ok:
		return strconv.Itoa(month.Number()), nil
	case len(during) == 0:
		return "*", nil
	}
	numbers := make([]int, len(during))
	for i, m := range during {
		numbers[i] = m.Number()
	}
	return listField(sortedUnique(numbers), 12), nil
}

func ownMonth(expr *ScheduleExpr) (MonthName, bool) {
	switch {
	case expr.Kind == ScheduleExprKindYear:
		return expr.YearTarget.Month, true
	case expr.Kind == ScheduleExprKindSingleDate && expr.DateSpec.Kind == DateSpecKindNamed:
		return expr.DateSpec.Month, true
	}
	return 0, false
}

func timeFields(expr *ScheduleExpr) (string, string, error) {
	times := minutesOfDay(expr)
	minutes := make([]int, len(times))
	hours := make([]int, len(times))
	for i, t := range times {
		minutes[i], hours[i] = t%60, t/60
	}
	minutes, hours = sortedUnique(minutes), sortedUnique(hours)
	if len(minutes)*len(hours) != len(times) {
		return "", "", notExpressible("times are not every combination of their minutes and hours")
	}
	return stepField(minutes, 60), stepField(hours, 24), nil
}

// Reuses the evaluator's slots, so conversion and evaluation agree on any interval.
func minutesOfDay(expr *ScheduleExpr) []int {
	var times []int
	if expr.Kind == ScheduleExprKindInterval {
		slots := intervalSlots(expr)
		for k := range slots.count {
			times = append(times, slots.minute(k))
		}
	} else {
		for _, t := range expr.Times {
			times = append(times, t.TotalMinutes())
		}
	}
	return sortedUnique(times)
}

func filterField(filter DayFilter) string {
	switch filter.Kind {
	case DayFilterKindEvery:
		return "*"
	case DayFilterKindWeekday:
		return weekdaysField([]Weekday{Monday, Tuesday, Wednesday, Thursday, Friday})
	case DayFilterKindWeekend:
		return weekdaysField([]Weekday{Saturday, Sunday})
	default:
		return weekdaysField(filter.Days)
	}
}

func weekdaysField(days []Weekday) string {
	numbers := make([]int, len(days))
	for i, d := range days {
		numbers[i] = d.CronDOW()
	}
	return listField(sortedUnique(numbers), 7)
}

func ordinalField(ordinal OrdinalPosition, weekday Weekday) string {
	if ordinal >= First && ordinal <= Fifth {
		return fmt.Sprintf("%d#%d", weekday.CronDOW(), ordinal)
	}
	return fmt.Sprintf("%dL", weekday.CronDOW())
}

func stepField(values []int, size int) string {
	first, last := values[0], values[len(values)-1]
	if len(values) == size {
		return "*"
	}
	if len(values) == 1 {
		return strconv.Itoa(first)
	}
	gap := values[1] - first
	equalGaps := true
	for i := 2; i < len(values); i++ {
		equalGaps = equalGaps && values[i]-values[i-1] == gap
	}
	switch {
	case equalGaps && first == 0 && last+gap == size:
		return fmt.Sprintf("*/%d", gap)
	case equalGaps && gap == 1:
		return fmt.Sprintf("%d-%d", first, last)
	case equalGaps && len(values) >= 3:
		return fmt.Sprintf("%d-%d/%d", first, last, gap)
	default:
		return listField(values, size)
	}
}

func listField(values []int, size int) string {
	if len(values) == size {
		return "*"
	}
	parts := make([]string, 0, len(values))
	for _, run := range runs(values) {
		if run[0] == run[1] {
			parts = append(parts, strconv.Itoa(run[0]))
		} else {
			parts = append(parts, fmt.Sprintf("%d-%d", run[0], run[1]))
		}
	}
	return strings.Join(parts, ",")
}

func runs(sortedValues []int) [][2]int {
	var runs [][2]int
	for _, value := range sortedValues {
		if n := len(runs); n > 0 && runs[n-1][1]+1 == value {
			runs[n-1][1] = value
		} else {
			runs = append(runs, [2]int{value, value})
		}
	}
	return runs
}

func sorted(values []int) []int {
	values = slices.Clone(values)
	slices.Sort(values)
	return values
}

func sortedUnique(values []int) []int {
	return slices.Compact(sorted(values))
}
