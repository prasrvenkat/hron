// Package hron provides parsing and evaluation of human-readable cron expressions.
package hron

import (
	"iter"
	"time"
)

// Schedule represents a parsed hron schedule.
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
	loc, err := resolveTimezone(data.Timezone)
	if err != nil {
		return nil, err
	}
	return &Schedule{
		data:     data,
		tzName:   data.Timezone,
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
func ParseSchedule(input string) (*Schedule, error) {
	data, err := Parse(input)
	if err != nil {
		return nil, err
	}
	return NewSchedule(data)
}

// FromCronExpr converts a 5-field cron expression to a Schedule.
func FromCronExpr(cronExpr string) (*Schedule, error) {
	data, err := FromCron(cronExpr)
	if err != nil {
		return nil, err
	}
	return NewSchedule(data)
}

// Validate checks if an input string is a valid hron expression.
func Validate(input string) bool {
	_, err := Parse(input)
	return err == nil
}

// NextFrom computes the next occurrence strictly after now.
// Returns nil if there is no future occurrence.
func (s *Schedule) NextFrom(now time.Time) *time.Time {
	return nextFrom(s.data, s.location, now)
}

// NextNFrom computes the next n occurrences strictly after now.
func (s *Schedule) NextNFrom(now time.Time, n int) []time.Time {
	return nextNFrom(s.data, s.location, now, n)
}

// PreviousFrom computes the most recent occurrence strictly before now.
// Returns nil if there is no earlier occurrence.
func (s *Schedule) PreviousFrom(now time.Time) *time.Time {
	return previousFrom(s.data, s.location, now)
}

// Matches checks if a datetime matches this schedule.
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

// ToCron converts this schedule to a 5-field cron expression.
// Returns an error if the schedule is not expressible as cron.
func (s *Schedule) ToCron() (string, error) {
	return ToCron(s.data)
}

// Timezone returns the IANA timezone name, or empty string if not specified.
func (s *Schedule) Timezone() string {
	return s.tzName
}

// Data returns the underlying ScheduleData.
func (s *Schedule) Data() *ScheduleData {
	return s.data
}
