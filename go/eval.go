package hron

import (
	"iter"
	"slices"
	"sort"
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

// How many dates past its scheduled date a fixed time can land: one shifted out
// of a gap before midnight lands on the next date.
const maxShiftDays = 1

// How many dates behind a date that has begun now's wall date can read: from
// the second pass of a fall-back overlap that crosses midnight, one.
const maxOverlapDays = 1

// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
const namedUntilMaxYears = 8

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
	// Not Truncate: it rounds the absolute instant, and LMT offsets carry seconds.
	minute := local.Add(-time.Duration(local.Second())*time.Second - time.Duration(local.Nanosecond()))
	// An occurrence never lands before the date it is scheduled on, so one at
	// this minute is scheduled on or before the minute's wall date.
	s.clauses.endOn(dateOf(minute))
	next, ok := s.nearest(minute.Add(-time.Nanosecond), forward)
	return ok && next.Equal(minute)
}

func occurrences(schedule *Schedule, from time.Time) iter.Seq[time.Time] {
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

func between(schedule *Schedule, from, to time.Time) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		if !inSupportedRange(to) {
			return
		}
		for t := range occurrences(schedule, from) {
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

func (d direction) sign() int64 {
	return int64(d)
}

func (d direction) precedes(a, b time.Time) bool {
	if d == forward {
		return a.Before(b)
	}
	return a.After(b)
}

type search struct {
	expr    *ScheduleExpr
	zone    *time.Location
	cadence cadence
	times   dailyTimes
	clauses clauses
}

func newSearch(data *ScheduleData, zone *time.Location) search {
	clauses := clausesOf(data)
	return search{
		expr:    &data.Expression,
		zone:    zone,
		cadence: cadenceOf(&data.Expression, clauses.starting),
		times:   dailyTimesOf(&data.Expression),
		clauses: clauses,
	}
}

type occurrence struct {
	instant time.Time
	landing time.Time
}

func (s *search) nearest(now time.Time, d direction) (time.Time, bool) {
	now = now.In(s.zone)
	nowDate := dateOf(now)
	firstDate := s.clauses.clamp(nowDate, d)
	// A nearest weekday or a DST shift can move an occurrence out of the
	// period it is scheduled in, so the search starts one period back.
	firstPeriod := s.cadence.periodOf(firstDate) - d.sign()
	reach := firstPeriod
	if date, ok := s.clauses.farthestExceptDate(d); ok {
		reach = s.cadence.periodOf(date)
	}
	shift := s.times.maxShiftDays()
	var best *occurrence
	periods := s.cadence.periodStarts(firstPeriod, reach, d)
walk:
	for start, ok := periods.next(); ok; start, ok = periods.next() {
		if s.cadence.targetsStartMonth() && !s.clauses.allowsMonth(start.Month()) {
			continue
		}
		candidates := candidatesInPeriod(s.expr, start)
		if d == backward {
			slices.Reverse(candidates)
		}
		for _, c := range candidates {
			if (best != nil && !couldBeat(c.date, best.landing, d, shift)) || s.clauses.endsSearch(c.date, d) {
				break walk
			}
			if isBehind(c.date, nowDate, d, shift) || !s.clauses.allows(c) {
				continue
			}
			instant, ok := s.nearestOnDate(c.date, now, d)
			if ok && (best == nil || d.precedes(instant, best.instant)) {
				best = &occurrence{instant, dateOf(instant)}
			}
		}
	}
	if best == nil || !inSupportedRange(best.instant) {
		return time.Time{}, false
	}
	return best.instant, true
}

func (s *search) nearestOnDate(date, now time.Time, d direction) (time.Time, bool) {
	if s.times.fixed != nil {
		return s.nearestFixedTime(date, now, d)
	}
	return s.nearestSlot(date, now, d)
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

func (s *search) nearestSlot(date, now time.Time, d direction) (time.Time, bool) {
	slots := s.times.slots
	at := func(k int) slot { return slotOn(date, slots.minute(k), s.zone) }
	atNow := d == forward
	// resolveWallClock reads the offsets a day either side of a wall time, so
	// the date's slots resolve with those from a day before it to a day after
	// it: two at most, as tzdata has no offset changes closer than about four
	// days. On most dates they are one, and the bounds meet.
	before := offsetAt(date.Add(-24*time.Hour), s.zone)
	after := offsetAt(date.Add(48*time.Hour), s.zone)
	lo, hi := slots.behindBounds(date, now, atNow, before, after)
	if lo < hi {
		// The keys still in question lie within the offsets' spread of now,
		// so the offsets there bound them too, and meet unless a transition
		// is that near.
		spread := max(before, after) - min(before, after)
		nearLo, nearHi := slots.behindBounds(date, now, atNow,
			offsetAt(now.Add(-spread), s.zone), offsetAt(now.Add(spread), s.zone))
		lo, hi = max(lo, nearLo), min(hi, nearHi)
	}
	behind := lo + sort.Search(hi-lo, func(i int) bool {
		key := at(lo + i).key
		return key.After(now) || !atNow && key.Equal(now)
	})
	if d == forward {
		for k := behind; k < slots.count; k++ {
			if slot := at(k); !slot.skipped {
				return slot.instant, true
			}
		}
	} else {
		for k := behind - 1; k >= 0; k-- {
			if slot := at(k); !slot.skipped {
				return slot.instant, true
			}
		}
	}
	return time.Time{}, false
}

// An occurrence lands from its scheduled date to shift dates after it, on a
// first pass, and first passes keep wall-clock order.
func couldBeat(date, landing time.Time, d direction, shift int) bool {
	if d == forward {
		return !date.After(landing)
	}
	return daysBetween(date, landing) <= shift
}

func isBehind(date, nowDate time.Time, d direction, shift int) bool {
	if d == forward {
		return daysBetween(date, nowDate) > shift
	}
	return daysBetween(nowDate, date) > maxOverlapDays
}

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

type slots struct {
	from, step, count int
}

func intervalSlots(expr *ScheduleExpr) slots {
	// Any step longer than a day leaves only the from slot, and this cap keeps the hours
	// conversion within a 32-bit int.
	step := min(expr.Interval, minutesPerDay+1)
	if expr.Unit == IntervalHours {
		step *= minutesPerHour
	}
	from, to := expr.FromTime.TotalMinutes(), expr.ToTime.TotalMinutes()
	return slots{from: from, step: step, count: max(floorDiv(to-from, step)+1, 0)}
}

// A gap pushes a fixed time forward, and skips a slot.
func (t *dailyTimes) maxShiftDays() int {
	if t.fixed != nil {
		return maxShiftDays
	}
	return 0
}

func (s slots) minute(k int) int {
	return s.from + k*s.step
}

// A key lies between its wall time read at the larger offset and at the
// smaller, so the slots behind now number between the counts read at each.
func (s slots) behindBounds(date, now time.Time, atNow bool, a, b time.Duration) (lo, hi int) {
	return s.wallBehind(date, now, min(a, b), atNow), s.wallBehind(date, now, max(a, b), atNow)
}

func (s slots) wallBehind(date, now time.Time, offset time.Duration, atNow bool) int {
	seconds := now.Unix() + int64(offset/time.Second) - date.Unix()
	minute := seconds / 60
	if seconds%60 < 0 {
		minute--
	}
	if !atNow && seconds%60 == 0 && now.Nanosecond() == 0 {
		minute--
	}
	// Clamped first so int(minute) cannot overflow on 32-bit for a date far from now.
	minute = min(max(minute, -1), minutesPerDay)
	return min(max(floorDiv(int(minute)-s.from, s.step)+1, 0), s.count)
}

type monthDay struct {
	month time.Month
	day   int
}

// during applies to a candidate's target month; except, until and starting to
// its date (spec/README.md, "Nearest weekday and `during`", "The `starting`
// clause").
type clauses struct {
	during          []time.Month
	exceptMonthDays []monthDay
	exceptDates     []time.Time
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
			date, _ := parseISODate(exception.Date)
			c.exceptDates = append(c.exceptDates, date)
		}
	}
	slices.SortFunc(c.exceptDates, time.Time.Compare)
	if data.Starting != "" {
		starting, _ := parseISODate(data.Starting)
		c.starting = &starting
	}
	if data.Until != nil {
		c.until = resolveUntilDate(*data.Until, c.starting)
	}
	return c
}

func (c *clauses) allows(candidate candidate) bool {
	date := candidate.date
	return c.allowsMonth(candidate.targetMonth) &&
		!slices.Contains(c.exceptMonthDays, monthDay{date.Month(), date.Day()}) &&
		!slices.ContainsFunc(c.exceptDates, date.Equal) &&
		(c.until == nil || !date.After(*c.until)) &&
		(c.starting == nil || !date.Before(*c.starting))
}

func (c *clauses) allowsMonth(month time.Month) bool {
	return len(c.during) == 0 || slices.Contains(c.during, month)
}

func (c *clauses) endOn(date time.Time) {
	if c.until == nil || date.Before(*c.until) {
		c.until = &date
	}
}

// The calendar repeats only beyond the farthest one-off except date
// (spec/README.md, "Search horizon").
func (c *clauses) farthestExceptDate(d direction) (time.Time, bool) {
	if len(c.exceptDates) == 0 {
		return time.Time{}, false
	}
	if d == forward {
		return c.exceptDates[len(c.exceptDates)-1], true
	}
	return c.exceptDates[0], true
}

func (c *clauses) clamp(date time.Time, d direction) time.Time {
	switch {
	case d == forward && c.starting != nil && date.Before(*c.starting):
		return *c.starting
	case d == backward && c.until != nil && date.After(*c.until):
		return *c.until
	}
	return date
}

func (c *clauses) endsSearch(date time.Time, d direction) bool {
	if d == forward {
		return c.until != nil && date.After(*c.until)
	}
	return c.starting != nil && date.Before(*c.starting)
}

// A named until resolves to its first date on or after starting, which every
// schedule with one has (spec/README.md, "Named `until`").
func resolveUntilDate(until UntilSpec, starting *time.Time) *time.Time {
	if until.Kind == UntilSpecKindISO {
		date, _ := parseISODate(until.Date)
		return &date
	}
	from := *starting
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

type cadence struct {
	unit     unit
	origin   time.Time
	interval int64

	single bool
}

func cadenceOf(expr *ScheduleExpr, starting *time.Time) cadence {
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
	if starting != nil {
		anchor = *starting
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
	return cadence{unit: u, origin: origin, interval: int64(interval)}
}

func (c *cadence) periodOf(date time.Time) int64 {
	switch c.unit {
	case unitDay:
		return int64(daysBetween(c.origin, date))
	case unitWeek:
		return int64(floorDiv(daysBetween(c.origin, date), 7))
	case unitMonth:
		return int64(monthIndex(date) - monthIndex(c.origin))
	default:
		return int64(date.Year() - c.origin.Year())
	}
}

func (c *cadence) targetsStartMonth() bool {
	return c.unit == unitDay || c.unit == unitMonth
}

// Every period further than calendarDays from the origin starts beyond the
// calendar, where only pastCalendar reads it, so k is clamped there and the int
// arithmetic below stays within 32 bits.
func (c *cadence) startOf(period int64) time.Time {
	k := int(min(max(period, -calendarDays), calendarDays))
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

// The walk reaches one search horizon beyond whichever of firstPeriod and
// reach is farther along d (spec/README.md, "Search horizon").
func (c *cadence) periodStarts(firstPeriod, reach int64, d direction) periodWalk {
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

func (c *cadence) align(k int64, d direction) int64 {
	if d == forward {
		return k + floorMod(-k, c.interval)
	}
	return k - floorMod(k, c.interval)
}

// horizonPeriods returns the aligned periods in lcm(400 years, interval units),
// after which both the calendar and the alignment repeat.
func (c *cadence) horizonPeriods() int64 {
	cycle := int64(c.unit.per400Years())
	return cycle / gcd(cycle, c.interval)
}

type periodWalk struct {
	cadence   *cadence
	period    int64
	step      int64
	left      int64
	direction direction
}

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
// each end. Year 0 holds a December whose next nearest weekday lands on
// 0001-01-01; a period starting after 10000 holds no supported instant.
var (
	calendarStart = newDate(0, time.January, 1)
	calendarEnd   = newDate(10000, time.December, 31)
)

const calendarDays = 10001 * 366

func pastCalendar(start time.Time, d direction) bool {
	if d == forward {
		return start.After(calendarEnd)
	}
	return start.Before(calendarStart)
}

// targetMonth differs from date's month only when a directional nearest
// weekday crosses into the adjacent month.
type candidate struct {
	date        time.Time
	targetMonth time.Month
}

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
func floorDiv[T int | int64](a, b T) T {
	q := a / b
	if a%b != 0 && (a < 0) != (b < 0) {
		q--
	}
	return q
}

func floorMod[T int | int64](a, b T) T {
	return a - floorDiv(a, b)*b
}

func gcd(a, b int64) int64 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}
