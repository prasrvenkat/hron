// Package hron provides parsing and evaluation of human-readable cron expressions.
package hron

import (
	"iter"
	"time"
)

// Schedule is a parsed hron expression. Its methods read only the instant of
// each time.Time passed in, and return times in the schedule's timezone, or UTC
// when it has none.
type Schedule struct {
	data     *ScheduleData
	tzName   string
	location *time.Location
}

// String returns the canonical hron expression for the schedule.
func (s *Schedule) String() string {
	return Display(s.data)
}

// NewSchedule creates a Schedule from parsed data. It returns an error if the
// timezone cannot be resolved.
func NewSchedule(data *ScheduleData) (*Schedule, error) {
	loc, tzName, err := resolveTimezone(data.Timezone)
	if err != nil {
		return nil, err
	}
	canonical := *data
	canonical.Timezone = tzName
	return &Schedule{
		data:     &canonical,
		tzName:   tzName,
		location: loc,
	}, nil
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
	data, err := Parse(input)
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
	data, err := FromCron(cronExpr)
	if err != nil {
		return nil, err
	}
	return NewSchedule(data)
}

// Validate reports false, rather than returning an error, for anything Parse rejects.
func Validate(input string) bool {
	_, err := Parse(input)
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
	return Occurrences(s, from)
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
func (s *Schedule) Between(from, to time.Time) iter.Seq[time.Time] {
	return Between(s, from, to)
}

// ToCron converts this schedule to the 5-field cron expression that fires at
// the same times on the same dates, in the schedule's timezone. The error is a
// *HronError of kind cron when no cron fires exactly as the schedule does.
func (s *Schedule) ToCron() (string, error) {
	return ToCron(s.data)
}

// Timezone returns the IANA timezone name with its canonical capitalization,
// or empty string if not specified.
func (s *Schedule) Timezone() string {
	return s.tzName
}

func (s *Schedule) Data() *ScheduleData {
	return s.data
}
