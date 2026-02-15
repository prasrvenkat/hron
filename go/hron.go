// Package hron provides parsing and evaluation of human-readable cron expressions.
//
// hron expressions are a superset of what cron can express, including:
// - Multi-week intervals
// - Ordinal weekdays (first monday, last friday)
// - Yearly schedules
// - Exception dates
// - End dates
// - IANA timezone support with full DST awareness
//
// Example usage:
//
//	schedule, err := hron.Parse("every weekday at 9:00 except dec 25 in America/New_York")
//	if err != nil {
//	    log.Fatal(err)
//	}
//
//	next := schedule.NextFrom(time.Now())
//	if next != nil {
//	    fmt.Println("Next occurrence:", next)
//	}
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

// Parse parses an hron expression string into a Schedule.
func (s *Schedule) String() string {
	return Display(s.data)
}

// NewSchedule creates a new Schedule from parsed data.
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
// This is the main entry point for parsing.
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

// NextFrom computes the next occurrence after now.
// Returns nil if there is no future occurrence.
func (s *Schedule) NextFrom(now time.Time) *time.Time {
	return nextFrom(s.data, now)
}

// NextNFrom computes the next n occurrences after now.
func (s *Schedule) NextNFrom(now time.Time, n int) []time.Time {
	return nextNFrom(s.data, now, n)
}

// Matches checks if a datetime matches this schedule.
func (s *Schedule) Matches(dt time.Time) bool {
	return matches(s.data, dt)
}

// Occurrences returns a lazy iterator of occurrences starting after `from`.
// The iterator is unbounded for repeating schedules (will iterate forever unless limited),
// but respects the `until` clause if specified in the schedule.
func (s *Schedule) Occurrences(from time.Time) iter.Seq[time.Time] {
	return Occurrences(s, from)
}

// Between returns a bounded iterator of occurrences where `from < occurrence <= to`.
// The iterator yields occurrences strictly after `from` and up to and including `to`.
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
