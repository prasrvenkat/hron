// Package hron provides parsing and evaluation of human-readable cron expressions.
package hron

import (
	"iter"
	"reflect"
	"slices"
	"time"
)

// Schedule is an hron schedule, parsed or built, and cannot change. Its
// methods read only the instant of each time.Time passed in, and return times
// in the schedule's timezone, or UTC when it has none.
type Schedule struct {
	data     *ScheduleData
	location *time.Location
}

// String returns the canonical hron expression for the schedule.
func (s *Schedule) String() string {
	return display(s.data)
}

// NewSchedule builds a Schedule from a copy of data, checked by the rules
// ParseSchedule applies, with the timezone in its IANA capitalization. The
// error is a *HronError of kind eval, with only a message, for the first part
// that breaks a rule.
func NewSchedule(data *ScheduleData) (*Schedule, error) {
	parts := copyParts(data)
	location, err := checkParts(parts)
	if err != nil {
		return nil, err
	}
	return &Schedule{data: parts, location: location}, nil
}

// MustParse parses an hron expression string into a Schedule.
// It panics if the input is invalid.
func MustParse(input string) *Schedule {
	s, err := ParseSchedule(input)
	if err != nil {
		panic(err)
	}
	return s
}

// ParseSchedule parses an hron expression string into a Schedule.
// The error is a *HronError.
func ParseSchedule(input string) (*Schedule, error) {
	data, err := parse(input)
	if err != nil {
		return nil, err
	}
	return NewSchedule(data)
}

// FromCronExpr converts a 5-field cron expression, or an @ shortcut, to the
// Schedule that fires at the same times on the same dates. The error is a
// *HronError of kind cron when the syntax is invalid or no hron schedule fires
// exactly as the cron does.
func FromCronExpr(cronExpr string) (*Schedule, error) {
	data, err := fromCron(cronExpr)
	if err != nil {
		return nil, err
	}
	return NewSchedule(data)
}

// Validate reports false, rather than returning an error, for anything ParseSchedule rejects.
func Validate(input string) bool {
	_, err := ParseSchedule(input)
	return err == nil
}

// NextFrom computes the next occurrence strictly after now.
// Returns nil if there is no future occurrence.
func (s *Schedule) NextFrom(now time.Time) *time.Time {
	return nextFrom(s.data, s.location, now)
}

// NextNFrom returns the next n occurrences strictly after now, fewer if the
// schedule ends first, and none when n <= 0.
func (s *Schedule) NextNFrom(now time.Time, n int) []time.Time {
	return firstN(s.Occurrences(now), n)
}

func firstN(occurrences iter.Seq[time.Time], n int) []time.Time {
	if n <= 0 {
		return nil
	}
	var results []time.Time
	for t := range occurrences {
		results = append(results, t)
		if len(results) == n {
			break
		}
	}
	return results
}

// PreviousFrom computes the most recent occurrence strictly before now.
// Returns nil if there is no earlier occurrence.
func (s *Schedule) PreviousFrom(now time.Time) *time.Time {
	return previousFrom(s.data, s.location, now)
}

// Matches reports whether the minute containing dt (seconds dropped) is an occurrence.
func (s *Schedule) Matches(dt time.Time) bool {
	return matches(s.data, s.location, dt)
}

// Occurrences returns a lazy iterator of occurrences strictly after from.
// Unbounded for repeating schedules unless an until clause ends them.
func (s *Schedule) Occurrences(from time.Time) iter.Seq[time.Time] {
	return occurrences(s, from)
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
func (s *Schedule) Between(from, to time.Time) iter.Seq[time.Time] {
	return between(s, from, to)
}

// ToCron converts this schedule to the 5-field cron expression that fires at
// the same times on the same dates, in the schedule's timezone. The error is a
// *HronError of kind cron when no cron fires exactly as the schedule does.
func (s *Schedule) ToCron() (string, error) {
	return toCron(s.data)
}

// Timezone returns the IANA timezone name with its canonical capitalization,
// or empty string if not specified.
func (s *Schedule) Timezone() string {
	return s.data.Timezone
}

// Expression returns a copy of the schedule's repeat.
func (s *Schedule) Expression() ScheduleExpr {
	return copyExpr(s.data.Expression)
}

// Except returns a copy of the except dates, or nil without an except clause.
func (s *Schedule) Except() []ExceptionSpec {
	return slices.Clone(s.data.Except)
}

// Until returns a copy of the until date, or nil without an until clause.
func (s *Schedule) Until() *UntilSpec {
	if s.data.Until == nil {
		return nil
	}
	until := *s.data.Until
	return &until
}

// Starting returns the starting date as YYYY-MM-DD, or "" without a starting clause.
func (s *Schedule) Starting() string {
	return s.data.Starting
}

// During returns a copy of the during months, or nil without a during clause.
func (s *Schedule) During() []MonthName {
	return slices.Clone(s.data.During)
}

// Data returns a copy of the schedule's parts, to change and pass to NewSchedule.
func (s *Schedule) Data() *ScheduleData {
	return copyParts(s.data)
}

// Equal reports whether other has the same parts, lists compared in order;
// false when other is nil. == on schedules compares identity instead.
func (s *Schedule) Equal(other *Schedule) bool {
	return other != nil && reflect.DeepEqual(s.data, other.data)
}
