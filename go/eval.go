package hron

import (
	"iter"
	"math"
	"slices"
	"time"
)

// Supported instants are rangeStart <= t < rangeEnd (spec/README.md,
// "Supported range").
var (
	rangeStart = time.Date(1, 1, 2, 0, 0, 0, 0, time.UTC)
	rangeEnd   = time.Date(9999, 12, 30, 0, 0, 0, 0, time.UTC)
)

// Slack beyond the horizon for the period one behind the first date's, where a
// search starts, and for a horizon that starts mid-period.
const horizonMarginPeriods = 2

// How many dates past its scheduled date an occurrence can land: a fixed time
// shifted out of a gap before midnight lands on the next date.
const maxShiftDays = 1

// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
const namedUntilMaxYears = 8

// The parser's limit on an interval. A schedule built by hand can exceed it;
// any larger interval fires as this one does in the supported range, and
// period arithmetic on it cannot overflow.
const maxInterval = math.MaxInt32

// Default anchors for day, month and year intervals, and for week intervals
// (spec/README.md, "WeekRepeat epoch alignment").
var (
	epochDate   = newDate(1970, time.January, 1)
	epochMonday = newDate(1970, time.January, 5)
)

func inSupportedRange(t time.Time) bool {
	return !t.Before(rangeStart) && t.Before(rangeEnd)
}

func nextFrom(data *ScheduleData, zone *time.Location, now time.Time) *time.Time {
	return nearestFrom(data, zone, now, forward)
}

func previousFrom(data *ScheduleData, zone *time.Location, now time.Time) *time.Time {
	return nearestFrom(data, zone, now, backward)
}

func nearestFrom(data *ScheduleData, zone *time.Location, now time.Time, d direction) *time.Time {
	if !inSupportedRange(now) {
		return nil
	}
	s := newSearch(data, zone)
	if nearest, ok := s.nearest(now, d); ok {
		return &nearest
	}
	return nil
}

// matches is defined through the forward search, so the two can never disagree
// about what an occurrence is (spec/README.md, "matches is true exactly when
// the minute containing t is an occurrence").
func matches(data *ScheduleData, zone *time.Location, t time.Time) bool {
	if !inSupportedRange(t) {
		return false
	}
	s := newSearch(data, zone)
	local := t.In(zone)
	minute := local.Add(-time.Duration(local.Second())*time.Second - time.Duration(local.Nanosecond()))
	next, ok := s.nearest(minute.Add(-time.Nanosecond), forward)
	return ok && next.Equal(minute)
}

// Occurrences returns a lazy iterator of occurrences strictly after from.
// Unbounded for repeating schedules unless an until clause ends them.
func Occurrences(schedule *Schedule, from time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		s := newSearch(schedule.data, schedule.location)
		current := from
		for inSupportedRange(current) {
			next, ok := s.nearest(current, forward)
			if !ok || !yield(next) {
				return
			}
			current = next
		}
	}
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
func Between(schedule *Schedule, from, to time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		if !inSupportedRange(to) {
			return
		}
		for t := range Occurrences(schedule, from) {
			if t.After(to) || !yield(t) {
				return
			}
		}
	}
}

type direction int

const (
	forward  direction = 1
	backward direction = -1
)

func (d direction) sign() int {
	return int(d)
}

// precedes reports whether a comes before b in direction d.
func (d direction) precedes(a, b time.Time) bool {
	if d == forward {
		return a.Before(b)
	}
	return a.After(b)
}

// search is a schedule prepared for searching: its zone, cadence, times and
// clauses resolved once.
type search struct {
	expr    *ScheduleExpr
	zone    *time.Location
	cadence cadence
	times   dailyTimes
	clauses clauses
}

func newSearch(data *ScheduleData, zone *time.Location) search {
	return search{
		expr:    &data.Expr,
		zone:    zone,
		cadence: cadenceOf(data),
		times:   dailyTimesOf(&data.Expr),
		clauses: clausesOf(data),
	}
}

// occurrence is an instant a search found, with the date it is scheduled on.
type occurrence struct {
	instant time.Time
	date    time.Time
}

// nearest returns the occurrence nearest now strictly beyond it in direction d.
func (s *search) nearest(now time.Time, d direction) (time.Time, bool) {
	now = now.In(s.zone)
	firstDate := s.clauses.clamp(dateOf(now), d)
	// A nearest weekday or a DST shift can move an occurrence out of the
	// period it is scheduled in, so the search starts one period back.
	firstPeriod := s.cadence.periodOf(firstDate) - d.sign()
	reach := firstPeriod
	if date, ok := s.clauses.farthestExceptDate(d); ok {
		reach = s.cadence.periodOf(date)
	}
	var best *occurrence
	periods := s.cadence.periodStarts(firstPeriod, reach, d)
walk:
	for start, ok := periods.next(); ok; start, ok = periods.next() {
		candidates := candidatesInPeriod(s.expr, start)
		if d == backward {
			slices.Reverse(candidates)
		}
		for _, c := range candidates {
			if (best != nil && !couldBeat(c.date, best.date, d)) || s.clauses.endsSearch(c.date, d) {
				break walk
			}
			if !s.clauses.allows(c) {
				continue
			}
			instant, ok := s.nearestOnDate(c.date, now, d)
			if ok && (best == nil || d.precedes(instant, best.instant)) {
				best = &occurrence{instant, c.date}
			}
		}
	}
	if best == nil || !inSupportedRange(best.instant) {
		return time.Time{}, false
	}
	return best.instant, true
}

// nearestOnDate returns the occurrence on date nearest now strictly beyond it
// in direction d.
func (s *search) nearestOnDate(date, now time.Time, d direction) (time.Time, bool) {
	switch {
	case s.times.fixed != nil:
		return s.nearestFixedTime(date, now, d)
	case d == forward:
		return s.firstSlotAfter(date, now)
	default:
		return s.lastSlotBefore(date, now)
	}
}

// nearestFixedTime resolves every time, since one shifted out of a gap can land
// after a later wall time.
func (s *search) nearestFixedTime(date, now time.Time, d direction) (time.Time, bool) {
	var nearest time.Time
	found := false
	for _, minute := range s.times.fixed {
		instant := fixedTimeOn(date, minute, s.zone)
		if d.precedes(now, instant) && (!found || d.precedes(instant, nearest)) {
			nearest, found = instant, true
		}
	}
	return nearest, found
}

// firstSlotAfter skips, on now's date, the slots whose wall time is at or
// before now's: slots resolve in wall-clock order, so those have passed.
func (s *search) firstSlotAfter(date, now time.Time) (time.Time, bool) {
	slots := s.times.slots
	first := 0
	today := dateOf(now)
	switch {
	case date.Before(today):
		return time.Time{}, false
	case date.Equal(today):
		first = slots.upTo(minuteOfDay(now))
	}
	for k := first; k < slots.count; k++ {
		if instant, ok := slotOn(date, slots.minute(k), s.zone); ok && instant.After(now) {
			return instant, true
		}
	}
	return time.Time{}, false
}

// lastSlotBefore mirrors firstSlotAfter, except in the second pass of a
// fall-back overlap, where a slot with a later wall time, even on the next
// date, can be earlier than now.
func (s *search) lastSlotBefore(date, now time.Time) (time.Time, bool) {
	slots := s.times.slots
	end := slots.count
	if today := dateOf(now); !date.Before(today) && !inSecondPass(now, s.zone) {
		if date.After(today) {
			return time.Time{}, false
		}
		end = slots.upTo(minuteOfDay(now))
	}
	for k := end - 1; k >= 0; k-- {
		if instant, ok := slotOn(date, slots.minute(k), s.zone); ok && instant.Before(now) {
			return instant, true
		}
	}
	return time.Time{}, false
}

// couldBeat reports whether an occurrence scheduled on date can precede, in
// direction d, the best one, scheduled on best, given that each lands at most
// maxShiftDays after its date.
func couldBeat(date, best time.Time, d direction) bool {
	return d.sign()*daysBetween(best, date) <= maxShiftDays
}

// dailyTimes are the times of day an expression fires at: fixed times in
// minutes after midnight, each shifted out of a gap, or, when fixed is nil,
// interval slots, each skipped in a gap.
type dailyTimes struct {
	fixed []int
	slots slots
}

func dailyTimesOf(expr *ScheduleExpr) dailyTimes {
	if expr.Kind == ScheduleExprKindInterval {
		return dailyTimes{slots: intervalSlots(expr)}
	}
	fixed := make([]int, len(expr.Times))
	for i, t := range expr.Times {
		fixed[i] = t.TotalMinutes()
	}
	return dailyTimes{fixed: fixed}
}

// slots are the wall-clock minutes from + k × step for 0 <= k < count.
type slots struct {
	from, step, count int
}

// intervalSlots returns the slots from + k × interval up to and including to.
func intervalSlots(expr *ScheduleExpr) slots {
	step := min(max(expr.Interval, 1), maxInterval)
	if expr.Unit == IntervalHours {
		step *= minutesPerHour
	}
	from, to := expr.FromTime.TotalMinutes(), expr.ToTime.TotalMinutes()
	return slots{from: from, step: step, count: max(floorDiv(to-from, step)+1, 0)}
}

func (s slots) minute(k int) int {
	return s.from + k*s.step
}

// upTo returns how many slots are at or before minute.
func (s slots) upTo(minute int) int {
	return min(max(floorDiv(minute-s.from, s.step)+1, 0), s.count)
}

type monthDay struct {
	month time.Month
	day   int
}

// clauses are the trailing clauses, resolved once. during applies to a
// candidate's target month; except, until and starting to its date
// (spec/README.md, "Nearest weekday and `during`", "The `starting` clause").
type clauses struct {
	during          []time.Month
	exceptMonthDays []monthDay
	exceptDates     []time.Time // ascending
	until           *time.Time
	starting        *time.Time
}

func clausesOf(data *ScheduleData) clauses {
	var c clauses
	for _, month := range data.During {
		c.during = append(c.during, time.Month(month.Number()))
	}
	for _, exception := range data.Except {
		switch exception.Kind {
		case ExceptionSpecKindNamed:
			c.exceptMonthDays = append(c.exceptMonthDays, monthDay{time.Month(exception.Month.Number()), exception.Day})
		case ExceptionSpecKindISO:
			if date, err := parseISODate(exception.Date); err == nil {
				c.exceptDates = append(c.exceptDates, date)
			}
		}
	}
	slices.SortFunc(c.exceptDates, time.Time.Compare)
	if data.Anchor != "" {
		starting, _ := parseISODate(data.Anchor)
		c.starting = &starting
	}
	if data.Until != nil {
		c.until = resolveUntilDate(*data.Until, c.starting)
	}
	return c
}

func (c *clauses) allows(candidate candidate) bool {
	date := candidate.date
	return (len(c.during) == 0 || slices.Contains(c.during, candidate.targetMonth)) &&
		!slices.Contains(c.exceptMonthDays, monthDay{date.Month(), date.Day()}) &&
		!slices.ContainsFunc(c.exceptDates, date.Equal) &&
		(c.until == nil || !date.After(*c.until)) &&
		(c.starting == nil || !date.Before(*c.starting))
}

// farthestExceptDate returns the one-off except date farthest along direction
// d: the calendar repeats only beyond it (spec/README.md, "Search horizon").
func (c *clauses) farthestExceptDate(d direction) (time.Time, bool) {
	if len(c.exceptDates) == 0 {
		return time.Time{}, false
	}
	if d == forward {
		return c.exceptDates[len(c.exceptDates)-1], true
	}
	return c.exceptDates[0], true
}

// clamp returns the date a search starts from: nothing fires before starting
// or after until.
func (c *clauses) clamp(date time.Time, d direction) time.Time {
	switch {
	case d == forward && c.starting != nil && date.Before(*c.starting):
		return *c.starting
	case d == backward && c.until != nil && date.After(*c.until):
		return *c.until
	}
	return date
}

// endsSearch reports whether date, and every date beyond it in direction d, is
// past the bound the search moves toward.
func (c *clauses) endsSearch(date time.Time, d direction) bool {
	if d == forward {
		return c.until != nil && date.After(*c.until)
	}
	return c.starting != nil && date.Before(*c.starting)
}

// resolveUntilDate returns the last date a schedule fires on. A named until
// date is the first such date on or after the starting date (spec/README.md,
// "Named `until`"). Parse requires starting; a schedule built without one
// resolves from the default anchor, the epoch. Nil when no such date exists,
// so nothing bounds the schedule.
func resolveUntilDate(until UntilSpec, starting *time.Time) *time.Time {
	if until.Kind == UntilSpecKindISO {
		date, _ := parseISODate(until.Date)
		return &date
	}
	from := epochDate
	if starting != nil {
		from = *starting
	}
	for year := from.Year(); year <= from.Year()+namedUntilMaxYears; year++ {
		if date, ok := validDate(year, time.Month(until.Month.Number()), until.Day); ok && !date.Before(from) {
			return &date
		}
	}
	return nil
}

type unit int

const (
	unitDay unit = iota
	unitWeek
	unitMonth
	unitYear
)

// per400Years returns the units in 400 years, after which the proleptic
// Gregorian calendar repeats.
func (u unit) per400Years() int {
	switch u {
	case unitDay:
		return 146097
	case unitWeek:
		return 20871
	case unitMonth:
		return 4800
	default:
		return 400
	}
}

// cadence is the periods (days, weeks, months or years) an expression fires
// in, numbered from origin: period k is aligned when k is a multiple of interval.
type cadence struct {
	unit     unit
	origin   time.Time
	interval int
	// A single ISO date has one period, the one holding that date.
	single bool
}

func cadenceOf(data *ScheduleData) cadence {
	expr := &data.Expr
	u, interval, defaultOrigin := unitDay, expr.Interval, epochDate
	switch expr.Kind {
	case ScheduleExprKindSingleDate:
		if expr.DateSpec.Kind == DateSpecKindISO {
			date, _ := parseISODate(expr.DateSpec.Date)
			return cadence{unit: unitDay, origin: date, interval: 1, single: true}
		}
		u, interval = unitYear, 1
	case ScheduleExprKindInterval:
		interval = 1
	case ScheduleExprKindWeek:
		u, defaultOrigin = unitWeek, epochMonday
	case ScheduleExprKindMonth:
		u = unitMonth
	case ScheduleExprKindYear:
		u = unitYear
	}
	anchor := defaultOrigin
	if data.Anchor != "" {
		anchor, _ = parseISODate(data.Anchor)
	}
	origin := anchor
	switch u {
	case unitWeek:
		origin = mondayOfWeek(anchor)
	case unitMonth:
		origin = newDate(anchor.Year(), anchor.Month(), 1)
	case unitYear:
		origin = newDate(anchor.Year(), time.January, 1)
	}
	return cadence{unit: u, origin: origin, interval: min(max(interval, 1), maxInterval)}
}

func (c *cadence) periodOf(date time.Time) int {
	switch c.unit {
	case unitDay:
		return daysBetween(c.origin, date)
	case unitWeek:
		return floorDiv(daysBetween(c.origin, date), 7)
	case unitMonth:
		return monthIndex(date) - monthIndex(c.origin)
	default:
		return date.Year() - c.origin.Year()
	}
}

// startOf returns the first day of period k.
func (c *cadence) startOf(k int) time.Time {
	switch c.unit {
	case unitDay:
		return addDays(c.origin, k)
	case unitWeek:
		return addDays(c.origin, 7*k)
	case unitMonth:
		year, month, _ := c.origin.Date()
		return newDate(year, month+time.Month(k), 1)
	default:
		return newDate(c.origin.Year()+k, time.January, 1)
	}
}

// periodStarts walks the first days of the aligned periods from firstPeriod in
// direction d, through one search horizon beyond whichever of firstPeriod and
// reach is farther along it (spec/README.md, "Search horizon").
func (c *cadence) periodStarts(firstPeriod, reach int, d direction) periodWalk {
	if c.single {
		return periodWalk{cadence: c, step: 1, left: 1, direction: d}
	}
	first := c.align(firstPeriod, d)
	beyond := d.sign() * (c.align(reach, d) - first)
	return periodWalk{
		cadence:   c,
		period:    first,
		step:      d.sign() * c.interval,
		left:      c.horizonPeriods() + horizonMarginPeriods + max(beyond, 0)/c.interval,
		direction: d,
	}
}

// align returns the first aligned period at or beyond period k in direction d.
func (c *cadence) align(k int, d direction) int {
	if d == forward {
		return k + floorMod(-k, c.interval)
	}
	return k - floorMod(k, c.interval)
}

// horizonPeriods returns the aligned periods in lcm(400 years, interval units),
// after which both the calendar and the alignment repeat.
func (c *cadence) horizonPeriods() int {
	cycle := c.unit.per400Years()
	return cycle / gcd(cycle, c.interval)
}

type periodWalk struct {
	cadence   *cadence
	period    int
	step      int
	left      int
	direction direction
}

// next returns the first day of the next period, or false once the walk is
// done or past the calendar's edge in its direction.
func (w *periodWalk) next() (time.Time, bool) {
	if w.left == 0 {
		return time.Time{}, false
	}
	start := w.cadence.startOf(w.period)
	if pastCalendar(start, w.direction) {
		w.left = 0
		return time.Time{}, false
	}
	w.period += w.step
	w.left--
	return start, true
}

// The calendar a search walks: the years an ISO date can name, and one more at
// each end for a period that holds dates in them, as a December whose next
// nearest weekday is in January does. A period starting outside it holds no
// occurrence in the supported range, and date arithmetic far outside it can
// overflow.
var (
	calendarStart = newDate(0, time.January, 1)
	calendarEnd   = newDate(10000, time.December, 31)
)

// pastCalendar reports whether a period starting at start, and every one
// beyond it in direction d, is outside the calendar.
func pastCalendar(start time.Time, d direction) bool {
	if d == forward {
		return start.After(calendarEnd)
	}
	return start.Before(calendarStart)
}

// candidate is a date an expression fires on, with the month whose day it
// names. They differ only when a directional nearest weekday crosses into the
// adjacent month.
type candidate struct {
	date        time.Time
	targetMonth time.Month
}

// candidatesInPeriod returns the candidates in the period starting at start,
// earliest first.
func candidatesInPeriod(expr *ScheduleExpr, start time.Time) []candidate {
	dates := datesInPeriod(expr, start)
	candidates := make([]candidate, len(dates))
	for i, date := range dates {
		candidates[i] = candidate{date, date.Month()}
		if expr.Kind == ScheduleExprKindMonth {
			candidates[i].targetMonth = start.Month()
		}
	}
	return candidates
}

func datesInPeriod(expr *ScheduleExpr, start time.Time) []time.Time {
	switch expr.Kind {
	case ScheduleExprKindInterval:
		if expr.DayFilter == nil || matchesDayFilter(start, *expr.DayFilter) {
			return []time.Time{start}
		}
	case ScheduleExprKindDay:
		if matchesDayFilter(start, expr.Days) {
			return []time.Time{start}
		}
	case ScheduleExprKindWeek:
		dates := make([]time.Time, len(expr.WeekDays))
		for i, day := range expr.WeekDays {
			dates[i] = addDays(start, day.Number()-1)
		}
		slices.SortFunc(dates, time.Time.Compare)
		return dates
	case ScheduleExprKindMonth:
		year, month, _ := start.Date()
		return monthTargetDates(year, month, expr.MonthTarget)
	case ScheduleExprKindYear:
		if date, ok := yearTargetDate(start.Year(), expr.YearTarget); ok {
			return []time.Time{date}
		}
	case ScheduleExprKindSingleDate:
		if expr.DateSpec.Kind == DateSpecKindISO {
			return []time.Time{start}
		}
		if date, ok := validDate(start.Year(), time.Month(expr.DateSpec.Month.Number()), expr.DateSpec.Day); ok {
			return []time.Time{date}
		}
	}
	return nil
}

// floorDiv rounds toward negative infinity where Go's / truncates toward zero,
// so dates before an origin align by floor (spec/README.md, "previousFrom
// mirrors nextFrom").
func floorDiv(a, b int) int {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func floorMod(a, b int) int {
	return a - floorDiv(a, b)*b
}

func gcd(a, b int) int {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}
