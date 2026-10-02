package hron

import (
	"errors"
	"math/rand/v2"
	"reflect"
	"testing"
)

var nine = []TimeOfDay{{9, 0}}

func daily(expr ScheduleExpr) *ScheduleData {
	return &ScheduleData{Expression: expr}
}

func withExcept(exceptions ...ExceptionSpec) *ScheduleData {
	return &ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Except: exceptions}
}

func withUntil(until UntilSpec) *ScheduleData {
	return &ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Until: &until, Starting: "2026-01-01"}
}

func evalMessage(t *testing.T, err error) string {
	t.Helper()
	var hronErr *HronError
	if !errors.As(err, &hronErr) || hronErr.Kind != ErrorKindEval || hronErr.Span != nil {
		t.Fatalf("got %v, want an eval error without a span", err)
	}
	return hronErr.Message
}

// spec/README.md, "Schedules built in code": in Go every enum is an int, so
// each can hold a value outside its kind.
func TestNewScheduleRejectsUnknownValues(t *testing.T) {
	dayFilter := func(kind DayFilterKind) *ScheduleData {
		return daily(NewIntervalRepeat(30, IntervalMin, TimeOfDay{9, 0}, TimeOfDay{17, 0}, &DayFilter{Kind: kind}))
	}
	month := func(target MonthTarget) *ScheduleData { return daily(NewMonthRepeat(1, target, nine)) }
	year := func(target YearTarget) *ScheduleData { return daily(NewYearRepeat(1, target, nine)) }
	cases := []struct {
		data *ScheduleData
		want string
	}{
		{daily(ScheduleExpr{Kind: 6, Times: nine}), "unknown expression 6"},
		{daily(ScheduleExpr{Kind: -1}), "unknown expression -1"},
		{daily(NewIntervalRepeat(30, 2, TimeOfDay{9, 0}, TimeOfDay{17, 0}, nil)), "unknown interval unit 2"},
		{dayFilter(4), "unknown day filter 4"},
		{dayFilter(-1), "unknown day filter -1"},
		{daily(NewDayRepeat(1, DayFilter{Kind: 9}, nine)), "unknown day filter 9"},
		{daily(NewDayRepeat(1, NewDayFilterDays([]Weekday{Monday, 8}), nine)), "unknown weekday 8"},
		{daily(NewWeekRepeat(1, []Weekday{0}, nine)), "unknown weekday 0"},
		{month(NewDaysTarget([]DayOfMonthSpec{NewSingleDay(1), {Kind: 2, Day: 1}})), "unknown day spec 2"},
		{month(MonthTarget{Kind: 5}), "unknown month target 5"},
		{month(NewNearestWeekdayTarget(15, 3)), "unknown direction 3"},
		{month(NewNearestWeekdayTarget(15, -1)), "unknown direction -1"},
		{month(NewOrdinalWeekdayTarget(0, Monday)), "unknown ordinal 0"},
		{month(NewOrdinalWeekdayTarget(7, Monday)), "unknown ordinal 7"},
		{month(NewOrdinalWeekdayTarget(Last, 8)), "unknown weekday 8"},
		{year(YearTarget{Kind: 4}), "unknown year target 4"},
		{year(NewYearDateTarget(13, 1)), "unknown month 13"},
		{year(NewYearDateTarget(0, 1)), "unknown month 0"},
		{year(NewYearOrdinalWeekdayTarget(9, Monday, Jan)), "unknown ordinal 9"},
		{year(NewYearOrdinalWeekdayTarget(First, 0, Jan)), "unknown weekday 0"},
		{year(NewYearOrdinalWeekdayTarget(First, Monday, 13)), "unknown month 13"},
		{year(NewYearDayOfMonthTarget(1, 13)), "unknown month 13"},
		{year(NewYearLastWeekdayTarget(-1)), "unknown month -1"},
		{daily(NewSingleDateExpr(DateSpec{Kind: 2}, nine)), "unknown date 2"},
		{daily(NewSingleDateExpr(NewNamedDate(13, 1), nine)), "unknown month 13"},
		{withExcept(ExceptionSpec{Kind: 2}), "unknown exception 2"},
		{withExcept(NewNamedException(0, 1)), "unknown month 0"},
		{withUntil(UntilSpec{Kind: 2}), "unknown until 2"},
		{withUntil(NewNamedUntil(13, 1)), "unknown month 13"},
		{&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), During: []MonthName{Jan, 13}}, "unknown month 13"},
	}
	for _, c := range cases {
		_, err := NewSchedule(c.data)
		if got := evalMessage(t, err); got != c.want {
			t.Errorf("%+v: %q, want %q", *c.data, got, c.want)
		}
	}
}

// A part is checked for a value outside its kind before its other rules,
// except a day repeat's every-day rule, which comes right after its interval.
func TestNewScheduleChecksUnknownValuesInOrder(t *testing.T) {
	cases := []struct {
		data *ScheduleData
		want string
	}{
		{daily(NewIntervalRepeat(0, 2, TimeOfDay{9, 0}, TimeOfDay{17, 0}, nil)), "interval must be 1-2147483647, got 0"},
		{daily(NewIntervalRepeat(30, 2, TimeOfDay{24, 0}, TimeOfDay{17, 0}, nil)), "unknown interval unit 2"},
		{daily(NewMonthRepeat(1, NewNearestWeekdayTarget(40, 9), nine)), "unknown direction 9"},
		{daily(NewYearRepeat(1, NewYearDayOfMonthTarget(32, 13), nine)), "unknown month 13"},
		{daily(NewYearRepeat(1, NewYearDateTarget(13, 0), nil)), "unknown month 13"},
		{daily(NewDayRepeat(2, DayFilter{Kind: 9}, nine)), "days must be every day when the interval is above 1"},
		{daily(NewDayRepeat(1, DayFilter{Kind: 9}, nil)), "unknown day filter 9"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(40), {Kind: 2}}), nine)), "day must be 1-31, got 40th"},
		{&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), During: []MonthName{13}, Timezone: "EST"}, "unknown month 13"},
	}
	for _, c := range cases {
		_, err := NewSchedule(c.data)
		if got := evalMessage(t, err); got != c.want {
			t.Errorf("%+v: %q, want %q", *c.data, got, c.want)
		}
	}
}

// Go's int lets an interval, a day and a time go below zero; each is written
// as display writes it.
func TestNewScheduleRejectsNegativeValues(t *testing.T) {
	cases := []struct {
		data *ScheduleData
		want string
	}{
		{daily(NewWeekRepeat(-1, []Weekday{Monday}, nine)), "interval must be 1-2147483647, got -1"},
		{daily(NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{-5, 0}})), "time must be 00:00-23:59, got -5:00"},
		{daily(NewDayRepeat(1, NewDayFilterEvery(), []TimeOfDay{{9, -1}})), "time must be 00:00-23:59, got 09:-1"},
		{daily(NewIntervalRepeat(30, IntervalMin, TimeOfDay{9, 0}, TimeOfDay{-123, 0}, nil)), "time must be 00:00-23:59, got -123:00"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-1)}), nine)), "day must be 1-31, got -1th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-7)}), nine)), "day must be 1-31, got -7th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-8)}), nine)), "day must be 1-31, got -8th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-9)}), nine)), "day must be 1-31, got -9th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-11)}), nine)), "day must be 1-31, got -11th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(-21)}), nine)), "day must be 1-31, got -21th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewDayRange(-3, 2)}), nine)), "day must be 1-31, got -3th"},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewDayRange(5, -9)}), nine)), "day must be 1-31, got -9th"},
		{daily(NewMonthRepeat(1, NewNearestWeekdayTarget(-9, NearestNone), nine)), "day must be 1-31, got -9th"},
		{daily(NewYearRepeat(1, NewYearDayOfMonthTarget(-8, Mar), nine)), "day must be 1-31, got -8th"},
		{daily(NewMonthRepeat(1, NewNearestWeekdayTarget(-2, NearestNone), nine)), "day must be 1-31, got -2th"},
		{daily(NewYearRepeat(1, NewYearDayOfMonthTarget(-1, Mar), nine)), "day must be 1-31, got -1th"},
		{daily(NewSingleDateExpr(NewNamedDate(Mar, -1), nine)), "day must be 1-31, got -1"},
		{withExcept(NewNamedException(Mar, -31)), "day must be 1-31, got -31"},
	}
	for _, c := range cases {
		_, err := NewSchedule(c.data)
		if got := evalMessage(t, err); got != c.want {
			t.Errorf("%+v: %q, want %q", *c.data, got, c.want)
		}
	}
}

func TestNewScheduleTakesTheEmptyTimezoneAsNone(t *testing.T) {
	s, err := NewSchedule(&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Timezone: ""})
	if err != nil {
		t.Fatal(err)
	}
	if s.Timezone() != "" || s.String() != "every day at 09:00" {
		t.Errorf("Timezone() = %q, String() = %q", s.Timezone(), s.String())
	}
}

func TestNewScheduleTakesTheEmptyStartingAsNone(t *testing.T) {
	s, err := NewSchedule(&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Starting: ""})
	if err != nil {
		t.Fatal(err)
	}
	if s.String() != "every day at 09:00" {
		t.Errorf("String() = %q", s.String())
	}
	until := NewNamedUntil(Dec, 31)
	_, err = NewSchedule(&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Until: &until, Starting: ""})
	if got, want := evalMessage(t, err), "until dec 31 has no year: add a starting date, or use an ISO date"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// spec/README.md, "Schedules built in code": a field the expression's kind
// does not use is not kept, and an empty except or during list is no clause,
// so the built schedule equals the parsed one.
func TestNewScheduleKeepsOnlyTheFieldsItsKindsUse(t *testing.T) {
	stray := ScheduleExpr{
		Interval:    7,
		Times:       nine,
		Unit:        IntervalHours,
		FromTime:    TimeOfDay{1, 2},
		ToTime:      TimeOfDay{3, 4},
		DayFilter:   &DayFilter{Kind: DayFilterKindWeekend},
		Days:        DayFilter{Kind: DayFilterKindDays, Days: []Weekday{Monday}},
		WeekDays:    []Weekday{Friday},
		MonthTarget: MonthTarget{Kind: MonthTargetKindLastDay, Specs: []DayOfMonthSpec{NewSingleDay(3)}, Day: 4},
		DateSpec:    DateSpec{Kind: DateSpecKindISO, Date: "2026-01-01", Month: Mar, Day: 3},
		YearTarget:  YearTarget{Kind: YearTargetKindLastWeekday, Month: Jun, Day: 9, Ordinal: Last, Weekday: Friday},
	}
	with := func(change func(*ScheduleExpr)) ScheduleExpr {
		expr := stray
		change(&expr)
		return expr
	}
	cases := []struct {
		data  *ScheduleData
		input string
	}{
		{daily(with(func(e *ScheduleExpr) { e.Kind, e.Interval, e.Days.Kind = ScheduleExprKindDay, 1, DayFilterKindEvery })), "every day at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind, e.Unit = ScheduleExprKindInterval, IntervalMin })), "every 7 min from 01:02 to 03:04 on weekend"},
		{daily(with(func(e *ScheduleExpr) { e.Kind = ScheduleExprKindWeek })), "every 7 weeks on friday at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind = ScheduleExprKindMonth })), "every 7 months on the last day at 09:00"},
		{daily(with(func(e *ScheduleExpr) {
			e.Kind, e.MonthTarget = ScheduleExprKindMonth, MonthTarget{Kind: MonthTargetKindOrdinalWeekday, Ordinal: First, Weekday: Monday, Day: 4, Specs: []DayOfMonthSpec{{}}}
		})), "every 7 months on the first monday at 09:00"},
		{daily(with(func(e *ScheduleExpr) {
			e.Kind, e.MonthTarget = ScheduleExprKindMonth, MonthTarget{Kind: MonthTargetKindDays, Specs: []DayOfMonthSpec{{Kind: DayOfMonthSpecKindSingle, Day: 2, Start: 5, End: 9}, {Kind: DayOfMonthSpecKindRange, Day: 2, Start: 5, End: 9}}, Ordinal: Last}
		})), "every 7 months on the 2nd, 5th to 9th at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind = ScheduleExprKindSingleDate })), "on 2026-01-01 at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind, e.DateSpec.Kind = ScheduleExprKindSingleDate, DateSpecKindNamed })), "on mar 3 at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind = ScheduleExprKindYear })), "every 7 years on the last weekday of jun at 09:00"},
		{daily(with(func(e *ScheduleExpr) { e.Kind, e.YearTarget.Kind = ScheduleExprKindYear, YearTargetKindDayOfMonth })), "every 7 years on the 9th of jun at 09:00"},
		{&ScheduleData{
			Expression: NewDayRepeat(1, NewDayFilterEvery(), nine),
			Except:     []ExceptionSpec{{Kind: ExceptionSpecKindNamed, Month: Jan, Day: 2, Date: "2026-01-02"}, {Kind: ExceptionSpecKindISO, Month: Jan, Day: 2, Date: "2026-01-03"}},
			Until:      &UntilSpec{Kind: UntilSpecKindISO, Date: "2026-12-31", Month: Dec, Day: 31},
		}, "every day at 09:00 except jan 2, 2026-01-03 until 2026-12-31"},
		{&ScheduleData{
			Expression: NewDayRepeat(1, NewDayFilterEvery(), nine),
			Until:      &UntilSpec{Kind: UntilSpecKindNamed, Date: "2026-12-31", Month: Dec, Day: 31},
			Starting:   "2026-01-01",
		}, "every day at 09:00 until dec 31 starting 2026-01-01"},
		{&ScheduleData{Expression: NewDayRepeat(1, NewDayFilterEvery(), nine), Except: []ExceptionSpec{}, During: []MonthName{}}, "every day at 09:00"},
	}
	for _, c := range cases {
		built, err := NewSchedule(c.data)
		if err != nil {
			t.Fatalf("%s: %v", c.input, err)
		}
		parsed := MustParse(c.input)
		if !reflect.DeepEqual(built.data, parsed.data) || !reflect.DeepEqual(built.Data(), parsed.Data()) {
			t.Errorf("built %+v\nparsed %+v", *built.data, *parsed.data)
		}
	}
}

func everyKindOfList() *ScheduleData {
	return &ScheduleData{
		Expression: NewIntervalRepeat(30, IntervalMin, TimeOfDay{9, 0}, TimeOfDay{17, 0}, &DayFilter{Kind: DayFilterKindDays, Days: []Weekday{Monday}}),
		Except:     []ExceptionSpec{NewISOException("2026-12-25")},
		Until:      &UntilSpec{Kind: UntilSpecKindISO, Date: "2027-01-01"},
		During:     []MonthName{Jan},
	}
}

func mutateEveryList(data *ScheduleData) {
	data.Expression.DayFilter.Days[0] = Friday
	data.Expression.DayFilter.Kind = DayFilterKindWeekend
	data.Expression.Times = append(data.Expression.Times, TimeOfDay{1, 0})
	data.Expression.Days.Days = append(data.Expression.Days.Days, Friday)
	data.Except[0].Date = "2026-12-26"
	data.Until.Date = "2028-01-01"
	data.During[0] = Feb
	data.Expression.Interval = 0
}

func mutateEveryDayList(data *ScheduleData) {
	data.Expression.Days.Days[0] = Friday
	data.Expression.Times[0] = TimeOfDay{10, 0}
}

func mutateEveryTargetList(data *ScheduleData) {
	data.Expression.MonthTarget.Specs[0] = NewSingleDay(2)
	data.Expression.Times[0] = TimeOfDay{10, 0}
}

func TestNewScheduleCopiesThePartsDeeply(t *testing.T) {
	cases := []struct {
		data   *ScheduleData
		mutate func(*ScheduleData)
	}{
		{everyKindOfList(), mutateEveryList},
		{daily(NewDayRepeat(1, NewDayFilterDays([]Weekday{Monday}), []TimeOfDay{{9, 0}})), mutateEveryDayList},
		{daily(NewWeekRepeat(1, []Weekday{Monday}, []TimeOfDay{{9, 0}})), func(d *ScheduleData) { d.Expression.WeekDays[0], d.Expression.Times[0] = Friday, TimeOfDay{10, 0} }},
		{daily(NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewSingleDay(1)}), []TimeOfDay{{9, 0}})), mutateEveryTargetList},
	}
	for _, c := range cases {
		s, err := NewSchedule(c.data)
		if err != nil {
			t.Fatal(err)
		}
		before, want := s.String(), s.Data()
		c.mutate(c.data)
		if s.String() != before || !reflect.DeepEqual(s.data, want) {
			t.Errorf("a change to the caller's parts changed %q to %q", before, s)
		}
	}
}

func TestDataReturnsACopyThatCannotChangeTheSchedule(t *testing.T) {
	cases := []struct {
		input  string
		mutate func(*ScheduleData)
	}{
		{"every 30 min from 09:00 to 17:00 on monday except 2026-12-25 until 2027-01-01 during jan", mutateEveryList},
		{"every monday at 09:00", mutateEveryDayList},
		{"every week on monday at 09:00", func(d *ScheduleData) { d.Expression.WeekDays[0], d.Expression.Times[0] = Friday, TimeOfDay{10, 0} }},
		{"every month on the 1st at 09:00", mutateEveryTargetList},
	}
	for _, c := range cases {
		s := MustParse(c.input)
		want := MustParse(c.input)
		c.mutate(s.Data())
		if s.String() != c.input || !reflect.DeepEqual(s.data, want.data) {
			t.Errorf("a change to Data() changed %q to %q", c.input, s)
		}
	}
}

func TestOrdinalPositionToN(t *testing.T) {
	want := map[OrdinalPosition]int{First: 1, Second: 2, Third: 3, Fourth: 4, Fifth: 5, Last: -1}
	for ordinal, n := range want {
		if got := ordinal.ToN(); got != n {
			t.Errorf("%s.ToN() = %d, want %d", ordinal, got, n)
		}
	}
}

func pick[T any](r *rand.Rand, values ...T) T {
	return values[r.IntN(len(values))]
}

func mostly[T any](r *rand.Rand, good, bad T) T {
	if r.IntN(20) == 0 {
		return bad
	}
	return good
}

// Mostly values that keep the rules, with values just past each limit mixed
// in, so that many parts build and many fail.
func randomParts(r *rand.Rand) *ScheduleData {
	time := func() TimeOfDay {
		return TimeOfDay{mostly(r, pick(r, 0, 9, 23), pick(r, 24, -1)), mostly(r, pick(r, 0, 30, 59), 60)}
	}
	times := func() []TimeOfDay {
		return mostly(r, pick(r, []TimeOfDay{time()}, []TimeOfDay{time(), time()}), nil)
	}
	interval := func() int { return mostly(r, pick(r, 1, 1, 2, maxInterval), pick(r, 0, -1)) }
	day := func() int { return mostly(r, pick(r, 1, 15, 28, 29, 30, 31), pick(r, 0, 32)) }
	weekday := func() Weekday { return pick(r, Monday, Saturday, Sunday) }
	weekdays := func() []Weekday {
		return mostly(r, pick(r, []Weekday{weekday()}, []Weekday{weekday(), weekday()}), nil)
	}
	month := func() MonthName { return pick(r, Jan, Feb, Apr) }
	dayFilter := func() DayFilter {
		return pick(r, NewDayFilterEvery(), NewDayFilterEvery(), NewDayFilterWeekday(), NewDayFilterWeekend(), NewDayFilterDays(weekdays()))
	}
	iso := func() string {
		return mostly(r, pick(r, "2026-02-28", "2028-02-29"), pick(r, "2026-02-29", "0000-01-01", "20260206"))
	}
	var expr ScheduleExpr
	switch r.IntN(6) {
	case 0:
		var filter *DayFilter
		if r.IntN(2) == 0 {
			f := dayFilter()
			filter = &f
		}
		expr = NewIntervalRepeat(interval(), pick(r, IntervalMin, IntervalHours), time(), time(), filter)
	case 1:
		expr = NewDayRepeat(interval(), dayFilter(), times())
	case 2:
		expr = NewWeekRepeat(interval(), weekdays(), times())
	case 3:
		a, b := day(), day()
		target := pick(r,
			NewDaysTarget([]DayOfMonthSpec{NewSingleDay(a)}),
			NewDaysTarget([]DayOfMonthSpec{NewDayRange(min(a, b), max(a, b)), NewSingleDay(b)}),
			NewDaysTarget(mostly(r, []DayOfMonthSpec{NewDayRange(min(a, b), max(a, b))}, []DayOfMonthSpec{NewDayRange(max(a, b), min(a, b))})),
			NewDaysTarget(mostly(r, []DayOfMonthSpec{NewSingleDay(a)}, nil)),
			NewLastDayTarget(),
			NewLastWeekdayTarget(),
			NewNearestWeekdayTarget(a, pick(r, NearestNone, NearestNext, NearestPrevious)),
			NewOrdinalWeekdayTarget(pick(r, First, Fifth, Last), weekday()),
		)
		expr = NewMonthRepeat(interval(), target, times())
	case 4:
		expr = NewSingleDateExpr(pick(r, NewNamedDate(month(), day()), NewISODate(iso())), times())
	default:
		target := pick(r,
			NewYearDateTarget(month(), day()),
			NewYearDayOfMonthTarget(day(), month()),
			NewYearOrdinalWeekdayTarget(pick(r, First, Fifth, Last), weekday(), month()),
			NewYearLastWeekdayTarget(month()),
		)
		expr = NewYearRepeat(interval(), target, times())
	}
	data := &ScheduleData{
		Expression: expr,
		Timezone:   mostly(r, pick(r, "", "utc", "america/new_york"), "EST"),
		Starting:   mostly(r, pick(r, "", "2026-02-06"), "0000-01-01"),
	}
	for range r.IntN(3) {
		data.Except = append(data.Except, pick(r, NewNamedException(month(), day()), NewISOException(iso())))
	}
	for range r.IntN(3) {
		data.During = append(data.During, month())
	}
	if r.IntN(2) == 0 {
		until := pick(r, NewNamedUntil(month(), day()), NewISOUntil(iso()))
		data.Until = &until
	}
	return data
}

// spec/README.md, "Schedules built in code": a built schedule keeps every
// promise a parsed one makes.
func TestBuiltSchedulesKeepThePromisesOfParsedOnes(t *testing.T) {
	r := rand.New(rand.NewPCG(0x6875_696C, 0x7421))
	built := 0
	const cases = 3000
	for range cases {
		parts := randomParts(r)
		s, err := NewSchedule(parts)
		if err != nil {
			evalMessage(t, err)
			continue
		}
		built++
		assertParsesBack(t, s)
		if _, err := s.ToCron(); err != nil {
			var hronErr *HronError
			if !errors.As(err, &hronErr) || hronErr.Kind != ErrorKindCron {
				t.Errorf("%q: ToCron() = %v, want a cron error", s, err)
			}
		}
		if next := s.NextFrom(friday); next != nil && !s.Matches(*next) {
			t.Errorf("%q: Matches(NextFrom) is false at %v", s, *next)
		}
		s.PreviousFrom(friday)
	}
	if built < cases/5 || built > cases*4/5 {
		t.Errorf("%d of %d random parts built, want between a fifth and four fifths", built, cases)
	}
}
