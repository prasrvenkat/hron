package hron

import (
	"fmt"
	"strings"
)

// Weekday represents a day of the week.
type Weekday int

const (
	Monday Weekday = iota + 1
	Tuesday
	Wednesday
	Thursday
	Friday
	Saturday
	Sunday
)

// Number returns the ISO 8601 day number (Monday=1, Sunday=7).
func (w Weekday) Number() int {
	return int(w)
}

// CronDOW returns the cron day of week number (Sunday=0, Monday=1, ..., Saturday=6).
func (w Weekday) CronDOW() int {
	cronDOW := map[Weekday]int{
		Sunday:    0,
		Monday:    1,
		Tuesday:   2,
		Wednesday: 3,
		Thursday:  4,
		Friday:    5,
		Saturday:  6,
	}
	return cronDOW[w]
}

func (w Weekday) String() string {
	names := map[Weekday]string{
		Monday:    "monday",
		Tuesday:   "tuesday",
		Wednesday: "wednesday",
		Thursday:  "thursday",
		Friday:    "friday",
		Saturday:  "saturday",
		Sunday:    "sunday",
	}
	return names[w]
}

// WeekdayFromNumber returns a Weekday from an ISO 8601 day number.
func WeekdayFromNumber(n int) (Weekday, bool) {
	if n < 1 || n > 7 {
		return 0, false
	}
	return Weekday(n), true
}

// ParseWeekday parses a weekday name (case insensitive).
func ParseWeekday(s string) (Weekday, bool) {
	weekdayParse := map[string]Weekday{
		"monday": Monday, "mon": Monday,
		"tuesday": Tuesday, "tue": Tuesday,
		"wednesday": Wednesday, "wed": Wednesday,
		"thursday": Thursday, "thu": Thursday,
		"friday": Friday, "fri": Friday,
		"saturday": Saturday, "sat": Saturday,
		"sunday": Sunday, "sun": Sunday,
	}
	w, ok := weekdayParse[strings.ToLower(s)]
	return w, ok
}

// MonthName represents a month of the year.
type MonthName int

const (
	Jan MonthName = iota + 1
	Feb
	Mar
	Apr
	May
	Jun
	Jul
	Aug
	Sep
	Oct
	Nov
	Dec
)

// Number returns the month number (January=1, December=12).
func (m MonthName) Number() int {
	return int(m)
}

func (m MonthName) String() string {
	names := map[MonthName]string{
		Jan: "jan", Feb: "feb", Mar: "mar", Apr: "apr",
		May: "may", Jun: "jun", Jul: "jul", Aug: "aug",
		Sep: "sep", Oct: "oct", Nov: "nov", Dec: "dec",
	}
	return names[m]
}

// ParseMonthName parses a month name (case insensitive).
func ParseMonthName(s string) (MonthName, bool) {
	monthParse := map[string]MonthName{
		"january": Jan, "jan": Jan,
		"february": Feb, "feb": Feb,
		"march": Mar, "mar": Mar,
		"april": Apr, "apr": Apr,
		"may":  May,
		"june": Jun, "jun": Jun,
		"july": Jul, "jul": Jul,
		"august": Aug, "aug": Aug,
		"september": Sep, "sep": Sep,
		"october": Oct, "oct": Oct,
		"november": Nov, "nov": Nov,
		"december": Dec, "dec": Dec,
	}
	m, ok := monthParse[strings.ToLower(s)]
	return m, ok
}

// IntervalUnit represents the unit of an interval (minutes or hours).
type IntervalUnit int

const (
	IntervalMin IntervalUnit = iota
	IntervalHours
)

func (u IntervalUnit) String() string {
	if u == IntervalMin {
		return "min"
	}
	return "hours"
}

// OrdinalPosition represents an ordinal position (first, second, etc.).
type OrdinalPosition int

const (
	First OrdinalPosition = iota + 1
	Second
	Third
	Fourth
	Fifth
	Last
)

// ToN returns the ordinal as a number (1-5, or -1 for Last).
func (o OrdinalPosition) ToN() int {
	if o == Last {
		return -1
	}
	return int(o)
}

func (o OrdinalPosition) String() string {
	names := map[OrdinalPosition]string{
		First:  "first",
		Second: "second",
		Third:  "third",
		Fourth: "fourth",
		Fifth:  "fifth",
		Last:   "last",
	}
	return names[o]
}

// ParseOrdinalPosition parses an ordinal position name (case insensitive).
func ParseOrdinalPosition(s string) (OrdinalPosition, bool) {
	ordinalParse := map[string]OrdinalPosition{
		"first":  First,
		"second": Second,
		"third":  Third,
		"fourth": Fourth,
		"fifth":  Fifth,
		"last":   Last,
	}
	o, ok := ordinalParse[strings.ToLower(s)]
	return o, ok
}

// TimeOfDay represents a time of day (hour and minute).
type TimeOfDay struct {
	Hour   int
	Minute int
}

func (t TimeOfDay) String() string {
	return fmt.Sprintf("%02d:%02d", t.Hour, t.Minute)
}

// TotalMinutes returns the time as total minutes from midnight.
func (t TimeOfDay) TotalMinutes() int {
	return t.Hour*60 + t.Minute
}

// --- Day filter ---

// DayFilterKind represents the type of day filter.
type DayFilterKind int

const (
	DayFilterKindEvery DayFilterKind = iota
	DayFilterKindWeekday
	DayFilterKindWeekend
	DayFilterKindDays
)

// DayFilter represents a filter for which days a schedule applies to.
type DayFilter struct {
	Kind DayFilterKind
	Days []Weekday // Only used when Kind == DayFilterKindDays
}

// NewDayFilterEvery creates a filter that matches every day.
func NewDayFilterEvery() DayFilter {
	return DayFilter{Kind: DayFilterKindEvery}
}

// NewDayFilterWeekday creates a filter that matches weekdays (Mon-Fri).
func NewDayFilterWeekday() DayFilter {
	return DayFilter{Kind: DayFilterKindWeekday}
}

// NewDayFilterWeekend creates a filter that matches weekends (Sat-Sun).
func NewDayFilterWeekend() DayFilter {
	return DayFilter{Kind: DayFilterKindWeekend}
}

// NewDayFilterDays creates a filter that matches specific days.
func NewDayFilterDays(days []Weekday) DayFilter {
	return DayFilter{Kind: DayFilterKindDays, Days: days}
}

// --- Day of month spec ---

// DayOfMonthSpecKind represents the type of day-of-month specification.
type DayOfMonthSpecKind int

const (
	DayOfMonthSpecKindSingle DayOfMonthSpecKind = iota
	DayOfMonthSpecKindRange
)

// DayOfMonthSpec represents a single day or range of days within a month.
type DayOfMonthSpec struct {
	Kind  DayOfMonthSpecKind
	Day   int // Used for single day
	Start int // Used for range
	End   int // Used for range
}

// NewSingleDay creates a single day specification.
func NewSingleDay(day int) DayOfMonthSpec {
	return DayOfMonthSpec{Kind: DayOfMonthSpecKindSingle, Day: day}
}

// NewDayRange creates a day range specification.
func NewDayRange(start, end int) DayOfMonthSpec {
	return DayOfMonthSpec{Kind: DayOfMonthSpecKindRange, Start: start, End: end}
}

// Expand returns all days in this specification.
func (d DayOfMonthSpec) Expand() []int {
	if d.Kind == DayOfMonthSpecKindSingle {
		return []int{d.Day}
	}
	var days []int
	for i := d.Start; i <= d.End; i++ {
		days = append(days, i)
	}
	return days
}

// --- Month target ---

// MonthTargetKind represents the type of month target.
type MonthTargetKind int

const (
	MonthTargetKindDays MonthTargetKind = iota
	MonthTargetKindLastDay
	MonthTargetKindLastWeekday
	MonthTargetKindNearestWeekday
	MonthTargetKindOrdinalWeekday
)

// NearestDirection represents the direction for nearest weekday calculations.
type NearestDirection int

const (
	// NearestNone means no direction (standard cron W behavior, never crosses month boundary)
	NearestNone NearestDirection = iota
	// NearestNext means always prefer following weekday (can cross to next month)
	NearestNext
	// NearestPrevious means always prefer preceding weekday (can cross to prev month)
	NearestPrevious
)

// MonthTarget represents which day(s) within a month a schedule fires on.
type MonthTarget struct {
	Kind      MonthTargetKind
	Specs     []DayOfMonthSpec // Only used when Kind == MonthTargetKindDays
	Day       int              // Only used when Kind == MonthTargetKindNearestWeekday
	Direction NearestDirection // Only used when Kind == MonthTargetKindNearestWeekday
	Ordinal   OrdinalPosition  // Only used when Kind == MonthTargetKindOrdinalWeekday
	Weekday   Weekday          // Only used when Kind == MonthTargetKindOrdinalWeekday
}

// NewDaysTarget creates a month target for specific days.
func NewDaysTarget(specs []DayOfMonthSpec) MonthTarget {
	return MonthTarget{Kind: MonthTargetKindDays, Specs: specs}
}

// NewLastDayTarget creates a month target for the last day of the month.
func NewLastDayTarget() MonthTarget {
	return MonthTarget{Kind: MonthTargetKindLastDay}
}

// NewLastWeekdayTarget creates a month target for the last weekday of the month.
func NewLastWeekdayTarget() MonthTarget {
	return MonthTarget{Kind: MonthTargetKindLastWeekday}
}

// NewNearestWeekdayTarget creates a month target for the nearest weekday to a given day.
func NewNearestWeekdayTarget(day int, direction NearestDirection) MonthTarget {
	return MonthTarget{Kind: MonthTargetKindNearestWeekday, Day: day, Direction: direction}
}

// NewOrdinalWeekdayTarget creates a month target for an ordinal weekday (e.g., first monday, last friday).
func NewOrdinalWeekdayTarget(ordinal OrdinalPosition, weekday Weekday) MonthTarget {
	return MonthTarget{Kind: MonthTargetKindOrdinalWeekday, Ordinal: ordinal, Weekday: weekday}
}

// ExpandDays returns all days specified by this target.
func (m MonthTarget) ExpandDays() []int {
	if m.Kind != MonthTargetKindDays {
		return nil
	}
	var days []int
	for _, spec := range m.Specs {
		days = append(days, spec.Expand()...)
	}
	return days
}

// --- Year target ---

// YearTargetKind represents the type of year target.
type YearTargetKind int

const (
	YearTargetKindDate YearTargetKind = iota
	YearTargetKindOrdinalWeekday
	YearTargetKindDayOfMonth
	YearTargetKindLastWeekday
)

// YearTarget represents which day within a year a schedule fires on.
type YearTarget struct {
	Kind    YearTargetKind
	Month   MonthName
	Day     int             // Used for Date and DayOfMonth
	Ordinal OrdinalPosition // Used for OrdinalWeekday
	Weekday Weekday         // Used for OrdinalWeekday
}

// NewYearDateTarget creates a year target for a specific month and day.
func NewYearDateTarget(month MonthName, day int) YearTarget {
	return YearTarget{Kind: YearTargetKindDate, Month: month, Day: day}
}

// NewYearOrdinalWeekdayTarget creates a year target for an ordinal weekday in a month.
func NewYearOrdinalWeekdayTarget(ordinal OrdinalPosition, weekday Weekday, month MonthName) YearTarget {
	return YearTarget{Kind: YearTargetKindOrdinalWeekday, Ordinal: ordinal, Weekday: weekday, Month: month}
}

// NewYearDayOfMonthTarget creates a year target for a specific day of a month.
func NewYearDayOfMonthTarget(day int, month MonthName) YearTarget {
	return YearTarget{Kind: YearTargetKindDayOfMonth, Day: day, Month: month}
}

// NewYearLastWeekdayTarget creates a year target for the last weekday of a month.
func NewYearLastWeekdayTarget(month MonthName) YearTarget {
	return YearTarget{Kind: YearTargetKindLastWeekday, Month: month}
}

// --- Date spec ---

// DateSpecKind represents the type of date specification.
type DateSpecKind int

const (
	DateSpecKindNamed DateSpecKind = iota
	DateSpecKindISO
)

// DateSpec represents a date (either named like "feb 14" or ISO like "2026-03-15").
type DateSpec struct {
	Kind  DateSpecKind
	Month MonthName // Used for named dates
	Day   int       // Used for named dates
	Date  string    // Used for ISO dates (YYYY-MM-DD)
}

// NewNamedDate creates a named date specification.
func NewNamedDate(month MonthName, day int) DateSpec {
	return DateSpec{Kind: DateSpecKindNamed, Month: month, Day: day}
}

// NewISODate creates an ISO date specification.
func NewISODate(date string) DateSpec {
	return DateSpec{Kind: DateSpecKindISO, Date: date}
}

// --- Exception spec ---

// ExceptionSpecKind represents the type of exception specification.
type ExceptionSpecKind int

const (
	ExceptionSpecKindNamed ExceptionSpecKind = iota
	ExceptionSpecKindISO
)

// ExceptionSpec represents an exception date.
type ExceptionSpec struct {
	Kind  ExceptionSpecKind
	Month MonthName // Used for named exceptions
	Day   int       // Used for named exceptions
	Date  string    // Used for ISO exceptions (YYYY-MM-DD)
}

// NewNamedException creates a named exception specification.
func NewNamedException(month MonthName, day int) ExceptionSpec {
	return ExceptionSpec{Kind: ExceptionSpecKindNamed, Month: month, Day: day}
}

// NewISOException creates an ISO exception specification.
func NewISOException(date string) ExceptionSpec {
	return ExceptionSpec{Kind: ExceptionSpecKindISO, Date: date}
}

// --- Until spec ---

// UntilSpecKind represents the type of until specification.
type UntilSpecKind int

const (
	UntilSpecKindISO UntilSpecKind = iota
	UntilSpecKindNamed
)

// UntilSpec represents an until date.
type UntilSpec struct {
	Kind  UntilSpecKind
	Date  string    // Used for ISO dates
	Month MonthName // Used for named dates
	Day   int       // Used for named dates
}

// NewISOUntil creates an ISO until specification.
func NewISOUntil(date string) UntilSpec {
	return UntilSpec{Kind: UntilSpecKindISO, Date: date}
}

// NewNamedUntil creates a named until specification.
func NewNamedUntil(month MonthName, day int) UntilSpec {
	return UntilSpec{Kind: UntilSpecKindNamed, Month: month, Day: day}
}

// --- Schedule expressions ---

// ScheduleExprKind represents the type of schedule expression.
type ScheduleExprKind int

const (
	ScheduleExprKindInterval ScheduleExprKind = iota
	ScheduleExprKindDay
	ScheduleExprKindWeek
	ScheduleExprKindMonth
	ScheduleExprKindSingleDate
	ScheduleExprKindYear
)

// ScheduleExpr represents a schedule expression (one of the 6 variants).
type ScheduleExpr struct {
	Kind ScheduleExprKind

	// Common fields
	Interval int
	Times    []TimeOfDay

	// IntervalRepeat fields
	Unit      IntervalUnit
	FromTime  TimeOfDay
	ToTime    TimeOfDay
	DayFilter *DayFilter // Optional for interval

	// DayRepeat fields
	Days DayFilter // Required for day repeat

	// WeekRepeat fields
	WeekDays []Weekday

	// MonthRepeat fields
	MonthTarget MonthTarget

	// SingleDateExpr fields
	DateSpec DateSpec

	// YearRepeat fields
	YearTarget YearTarget
}

// NewIntervalRepeat creates an interval repeat expression.
func NewIntervalRepeat(interval int, unit IntervalUnit, from, to TimeOfDay, dayFilter *DayFilter) ScheduleExpr {
	return ScheduleExpr{
		Kind:      ScheduleExprKindInterval,
		Interval:  interval,
		Unit:      unit,
		FromTime:  from,
		ToTime:    to,
		DayFilter: dayFilter,
	}
}

// NewDayRepeat creates a day repeat expression.
func NewDayRepeat(interval int, days DayFilter, times []TimeOfDay) ScheduleExpr {
	return ScheduleExpr{
		Kind:     ScheduleExprKindDay,
		Interval: interval,
		Days:     days,
		Times:    times,
	}
}

// NewWeekRepeat creates a week repeat expression.
func NewWeekRepeat(interval int, days []Weekday, times []TimeOfDay) ScheduleExpr {
	return ScheduleExpr{
		Kind:     ScheduleExprKindWeek,
		Interval: interval,
		WeekDays: days,
		Times:    times,
	}
}

// NewMonthRepeat creates a month repeat expression.
func NewMonthRepeat(interval int, target MonthTarget, times []TimeOfDay) ScheduleExpr {
	return ScheduleExpr{
		Kind:        ScheduleExprKindMonth,
		Interval:    interval,
		MonthTarget: target,
		Times:       times,
	}
}

// NewSingleDateExpr creates a single date expression.
func NewSingleDateExpr(date DateSpec, times []TimeOfDay) ScheduleExpr {
	return ScheduleExpr{
		Kind:     ScheduleExprKindSingleDate,
		DateSpec: date,
		Times:    times,
	}
}

// NewYearRepeat creates a year repeat expression.
func NewYearRepeat(interval int, target YearTarget, times []TimeOfDay) ScheduleExpr {
	return ScheduleExpr{
		Kind:       ScheduleExprKindYear,
		Interval:   interval,
		YearTarget: target,
		Times:      times,
	}
}

// --- Schedule data ---

// ScheduleData represents the complete parsed schedule with all clauses.
type ScheduleData struct {
	Expr     ScheduleExpr
	Timezone string
	Except   []ExceptionSpec
	Until    *UntilSpec
	Anchor   string // ISO date string for starting clause
	During   []MonthName
}

// NewScheduleData creates a new schedule data with just the expression.
func NewScheduleData(expr ScheduleExpr) *ScheduleData {
	return &ScheduleData{Expr: expr}
}
