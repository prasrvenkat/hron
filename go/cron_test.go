package hron

import (
	"errors"
	"fmt"
	"math"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Two years around 2044-02-29, a leap day in a February with five Mondays.
var (
	windowStart = time.Date(2043, 6, 1, 0, 0, 0, 0, time.UTC)
	windowEnd   = time.Date(2045, 6, 1, 0, 0, 0, 0, time.UTC)
)

const fullCompareLimit = 20_000

func cronMessage(t *testing.T, err error) string {
	t.Helper()
	var hronErr *HronError
	if !errors.As(err, &hronErr) || hronErr.Kind != ErrorKindCron {
		t.Fatalf("expected a cron error, got %v", err)
	}
	return hronErr.Message
}

func fromCronString(t *testing.T, cron string) string {
	t.Helper()
	data, err := FromCron(cron)
	if err != nil {
		t.Fatalf("FromCron(%q): %v", cron, err)
	}
	return Display(data)
}

func fromCronError(t *testing.T, cron string) string {
	t.Helper()
	_, err := FromCron(cron)
	return cronMessage(t, err)
}

// A cron matcher written from the cron rules alone, sharing no code with the
// package. It expects valid syntax.
type naiveCron struct {
	minutes, hours, months []bool
	dom                    naiveDom
	dow                    naiveDow
}

type naiveDom struct {
	kind string
	days []bool
	n    uint64
}

type naiveDow struct {
	kind   string
	days   []bool
	day, n uint64
}

var (
	naiveMonthNames = []string{"", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}
	naiveDayNames   = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
	naiveShortcuts  = map[string]string{
		"@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
		"@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *",
	}
)

func newNaiveCron(t *testing.T, cron string) naiveCron {
	t.Helper()
	cron = strings.ToLower(strings.TrimSpace(cron))
	if expanded, ok := naiveShortcuts[cron]; ok {
		cron = expanded
	}
	f := strings.Fields(cron)
	if len(f) != 5 {
		t.Fatalf("naive matcher given %q", cron)
	}
	var dom naiveDom
	switch d := f[2]; {
	case d == "*" || d == "?":
		dom = naiveDom{kind: "any"}
	case d == "l":
		dom = naiveDom{kind: "last"}
	case d == "lw":
		dom = naiveDom{kind: "lastWeekday"}
	case strings.HasSuffix(d, "w"):
		dom = naiveDom{kind: "nearest", n: naiveNumber(d[:len(d)-1], nil)}
	default:
		dom = naiveDom{kind: "days", days: naiveSet(d, 1, 31, 31, nil)}
	}
	var dow naiveDow
	switch d := f[4]; {
	case d == "*" || d == "?":
		dow = naiveDow{kind: "any"}
	case strings.Contains(d, "#"):
		day, nth, _ := strings.Cut(d, "#")
		dow = naiveDow{kind: "nth", day: naiveNumber(day, naiveDayNames) % 7, n: naiveNumber(nth, nil)}
	case strings.HasSuffix(d, "l"):
		dow = naiveDow{kind: "last", day: naiveNumber(d[:len(d)-1], naiveDayNames) % 7}
	default:
		days := naiveSet(d, 0, 7, 6, naiveDayNames)
		days[0] = days[0] || days[7]
		dow = naiveDow{kind: "days", days: days[:7]}
	}
	return naiveCron{
		minutes: naiveSet(f[0], 0, 59, 59, nil),
		hours:   naiveSet(f[1], 0, 23, 23, nil),
		months:  naiveSet(f[3], 1, 12, 12, naiveMonthNames),
		dom:     dom,
		dow:     dow,
	}
}

func (c naiveCron) times() [][2]int {
	var times [][2]int
	for hour := range 24 {
		for minute := range 60 {
			if c.hours[hour] && c.minutes[minute] {
				times = append(times, [2]int{hour, minute})
			}
		}
	}
	return times
}

func (c naiveCron) firesOn(d time.Time) bool {
	day := d.Day()
	last := time.Date(d.Year(), d.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day()
	weekday := uint64(d.Weekday())
	var weekdays []int
	for n := 1; n <= last; n++ {
		w := time.Date(d.Year(), d.Month(), n, 0, 0, 0, 0, time.UTC).Weekday()
		if w != time.Saturday && w != time.Sunday {
			weekdays = append(weekdays, n)
		}
	}
	var dom, dow *bool
	match := func(b bool) *bool { return &b }
	switch c.dom.kind {
	case "days":
		dom = match(c.dom.days[day])
	case "last":
		dom = match(day == last)
	case "lastWeekday":
		dom = match(day == weekdays[len(weekdays)-1])
	case "nearest":
		n := int(c.dom.n)
		nearest := weekdays[0]
		for _, w := range weekdays {
			if abs(w-n) < abs(nearest-n) {
				nearest = w
			}
		}
		dom = match(n <= last && day == nearest)
	}
	switch c.dow.kind {
	case "days":
		dow = match(c.dow.days[weekday])
	case "nth":
		dow = match(weekday == c.dow.day && uint64(day-1)/7+1 == c.dow.n)
	case "last":
		dow = match(weekday == c.dow.day && day+7 > last)
	}
	dayMatches := true
	switch {
	case dom != nil && dow != nil:
		dayMatches = *dom || *dow
	case dom != nil:
		dayMatches = *dom
	case dow != nil:
		dayMatches = *dow
	}
	return c.months[d.Month()] && dayMatches
}

func abs(n int) int {
	return max(n, -n)
}

func (c naiveCron) bothDaysRestricted() bool {
	return c.dom.kind != "any" && c.dow.kind != "any"
}

func (c naiveCron) daysCarryAnInterval() bool {
	switch {
	case c.dom.kind == "any":
		return c.dow.kind == "any" || c.dow.kind == "days"
	case c.dom.kind == "days" && c.dow.kind == "any":
		return !slices.Contains(c.dom.days[1:], false)
	}
	return false
}

func naiveNumber(text string, names []string) uint64 {
	if index := slices.Index(names, text); index >= 0 {
		return uint64(index)
	}
	n, err := strconv.ParseUint(text, 10, 64)
	if err != nil {
		return math.MaxUint64
	}
	return n
}

func naiveSet(field string, low, high, starHigh uint64, names []string) []bool {
	set := make([]bool, high+1)
	for _, item := range strings.Split(field, ",") {
		bounds, stepText, hasStep := strings.Cut(item, "/")
		step := uint64(1)
		if hasStep {
			step = naiveNumber(stepText, nil)
		}
		var first, last uint64
		if bounds == "*" {
			first, last = low, starHigh
		} else if a, b, isRange := strings.Cut(bounds, "-"); isRange {
			first, last = naiveNumber(a, names), naiveNumber(b, names)
		} else {
			first = naiveNumber(bounds, names)
			last = first
			if hasStep {
				last = max(first, starHigh)
			}
		}
		for value := first; value <= last; {
			set[value] = true
			if value > math.MaxUint64-step {
				break
			}
			value += step
		}
	}
	return set
}

func windowDays() []time.Time {
	var days []time.Time
	for d := windowStart; d.Before(windowEnd); d = d.AddDate(0, 0, 1) {
		days = append(days, d)
	}
	return days
}

type wallTime struct {
	date         string
	hour, minute int
}

func wallOf(t time.Time) wallTime {
	return wallTime{t.Format(time.DateOnly), t.Hour(), t.Minute()}
}

func wallAt(d time.Time, hm [2]int) wallTime {
	return wallTime{d.Format(time.DateOnly), hm[0], hm[1]}
}

func assertFiresAs(t *testing.T, schedule *Schedule, cron naiveCron, label string) {
	t.Helper()
	times := cron.times()
	var days []time.Time
	for _, d := range windowDays() {
		if cron.firesOn(d) {
			days = append(days, d)
		}
	}
	if len(days)*len(times) <= fullCompareLimit {
		assertEachOccurrence(t, schedule, days, times, windowEnd, label)
		return
	}
	assertEachOccurrence(t, schedule, days[:2], times, days[1].AddDate(0, 0, 1), label)
	// Too many to compare one by one. In UTC an hron schedule fires at the same
	// times on every day it fires, so the two days compared in full stand for the
	// times of the rest; on each day the first and the last time, searched from
	// the day before, show that it fires that day and on no day between.
	cursor := windowStart.Add(-time.Second)
	for _, d := range days {
		next := schedule.NextFrom(cursor)
		if next == nil || wallOf(*next) != wallAt(d, times[0]) {
			t.Fatalf("%s: first time on %s is %v", label, d.Format(time.DateOnly), next)
		}
		endOfDay := d.AddDate(0, 0, 1)
		previous := schedule.PreviousFrom(endOfDay)
		if previous == nil || wallOf(*previous) != wallAt(d, times[len(times)-1]) {
			t.Fatalf("%s: last time on %s is %v", label, d.Format(time.DateOnly), previous)
		}
		cursor = endOfDay.Add(-time.Second)
	}
	if after := schedule.NextFrom(cursor); after != nil && after.Before(windowEnd) {
		t.Fatalf("%s: fires on %v, after the last day the cron fires", label, after)
	}
}

func assertEachOccurrence(t *testing.T, schedule *Schedule, days []time.Time, times [][2]int, end time.Time, label string) {
	t.Helper()
	var expected []wallTime
	for _, d := range days {
		for _, hm := range times {
			expected = append(expected, wallAt(d, hm))
		}
	}
	i := 0
	for occurrence := range schedule.Between(windowStart.Add(-time.Second), end.Add(-time.Second)) {
		if i >= len(expected) {
			t.Fatalf("%s: unexpected occurrence %v", label, wallOf(occurrence))
		}
		if wallOf(occurrence) != expected[i] {
			t.Fatalf("%s: occurrence %d is %v, expected %v", label, i, wallOf(occurrence), expected[i])
		}
		i++
	}
	if i != len(expected) {
		t.Fatalf("%s: %d occurrences, expected %d, the next %v", label, i, len(expected), expected[i])
	}
}

func hasEqualGaps(times [][2]int) bool {
	if len(times) < 3 {
		return false
	}
	gap := times[1][0]*60 + times[1][1] - times[0][0]*60 - times[0][1]
	for i := 2; i < len(times); i++ {
		if times[i][0]*60+times[i][1]-times[i-1][0]*60-times[i-1][1] != gap {
			return false
		}
	}
	return true
}

func expectedFromCronMessage(times [][2]int) string {
	if hasEqualGaps(times) {
		return intervalDays
	}
	return fmt.Sprintf("not expressible in hron: %d times a day are too many to list", len(times))
}

// xorshift64*, so the generated cases are the same on every run.
type rng uint64

func (r *rng) pickIndex(n int) int {
	x := uint64(*r)
	x ^= x >> 12
	x ^= x << 25
	x ^= x >> 27
	*r = rng(x)
	return int((x * 0x2545_f491_4f6c_dd1d >> 32) % uint64(n))
}

func (r *rng) pick(items []string) string {
	return items[r.pickIndex(len(items))]
}

var (
	minuteFields = []string{
		"0", "30", "*/15", "0-30/10", "5,35", "*", "59", "*/7", "00", "10-50/20", "45/5", "0/20", "1-3",
		"*/99999999999999999999", "0,15,30,45", "5-10/5", "0-59/30", "*/20",
	}
	hourFields = []string{
		"9", "*", "*/2", "9-17", "9-17/2", "0,12", "23", "0-20/4", "*/5", "22,0,2", "1-23", "7/30", "009",
		"0-11", "*/1", "12-12/250", "0-16/4", "1-21/4",
	}
	domFields = []string{
		"*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29", "30", "lw", "1W", "31W",
		"*/2", "1-31", "5-20/3", "15,1", "02", "l", "28-31", "30W", "29w", "1-30", "2-31",
	}
	monthFields = []string{
		"*", "1", "JAN", "1-3", "*/3", "2", "dec", "4", "feb", "1,7", "jun-aug", "12,1", "*/12", "2/5",
		"12-12/250", "Sep", "2", "2",
	}
	dowFields = []string{
		"*", "1-5", "MON", "0", "7", "5L", "1#2", "SUN#1", "?", "1-5/2", "sat,sun", "0-7", "7/2", "5-7",
		"fri#5", "1#5", "0l", "mon-fri/2", "6,7", "7,1", "0-6", "5/1", "*/3", "tue-thu", "1,1,3", "1-4",
		"mon-thu", "1-6", "0-5", "0,6,1", "sun,sat",
	}
)

// Two crons in three keep one day field `*`, so most convert; the third draws
// both, so some are rejected for restricting both.
func generatedCrons(shard uint64) []string {
	r := rng(0x9e37_79b9_7f4a_7c15 ^ shard)
	star := []string{"*"}
	crons := make([]string, 150)
	for i := range crons {
		dom, dow := domFields, dowFields
		switch i % 3 {
		case 0:
			dow = star
		case 1:
			dom = star
		}
		fields := make([]string, 5)
		for j, field := range [][]string{minuteFields, hourFields, dom, monthFields, dow} {
			fields[j] = r.pick(field)
		}
		crons[i] = strings.Join(fields, " ")
	}
	return crons
}

func TestFromCronIsExact(t *testing.T) {
	for shard := range uint64(4) {
		t.Run(fmt.Sprintf("shard_%d", shard), func(t *testing.T) {
			t.Parallel()
			accepted := 0
			for _, cron := range generatedCrons(shard) {
				naive := newNaiveCron(t, cron)
				times := naive.times()
				data, err := FromCron(cron)
				if naive.bothDaysRestricted() {
					if got := cronMessage(t, err); got != bothDaysRestricted {
						t.Fatalf("%s: %q", cron, got)
					}
					continue
				}
				interval := naive.daysCarryAnInterval() && hasEqualGaps(times)
				if len(times) > 24 && !interval {
					if got, want := cronMessage(t, err), expectedFromCronMessage(times); got != want {
						t.Fatalf("%s: %q, want %q", cron, got, want)
					}
					continue
				}
				if err != nil {
					t.Fatalf("FromCron(%q): %v", cron, err)
				}
				schedule := mustSchedule(t, data)
				assertFiresAs(t, schedule, naive, cron)

				back, err := schedule.ToCron()
				if err != nil {
					t.Fatalf("ToCron of FromCron(%q) = %s: %v", cron, schedule, err)
				}
				label := fmt.Sprintf("%s -> %s -> %s", cron, schedule, back)
				again, err := FromCron(back)
				if err != nil {
					t.Fatalf("%s: %v", label, err)
				}
				if Display(again) != schedule.String() {
					assertFiresAs(t, mustSchedule(t, again), naive, label)
				}
				naiveBack := newNaiveCron(t, back)
				if !slices.Equal(naiveBack.times(), times) {
					t.Fatalf("%s: times %v, want %v", label, naiveBack.times(), times)
				}
				for _, d := range windowDays() {
					if naiveBack.firesOn(d) != naive.firesOn(d) {
						t.Fatalf("%s: differs on %s", label, d.Format(time.DateOnly))
					}
				}
				accepted++
			}
			if accepted < 60 {
				t.Fatalf("only %d generated crons were accepted", accepted)
			}
			t.Logf("%d of 150 generated crons converted", accepted)
		})
	}
}

var (
	timeLists = []string{
		"09:00",
		"00:00",
		"23:59",
		"09:00, 17:00",
		"17:00, 09:00, 09:00",
		"00:00, 12:00",
		"09:00, 13:00, 17:00",
		"09:00, 17:30",
		"00:05, 00:35",
		"00:00, 00:01, 00:02, 00:30",
		"00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10",
		"00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59",
		"00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00",
		"09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00, 15:30",
		"09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12, 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24",
	}
	// Each with the month it names, which a `during` must include.
	dayExpressions = [][2]string{
		{"every day", ""},
		{"every weekday", ""},
		{"every weekend", ""},
		{"every monday", ""},
		{"every sunday, saturday", ""},
		{"every friday, saturday, sunday", ""},
		{"every week on tuesday, friday", ""},
		{"every 1 day", ""},
		{"every month on the 1st", ""},
		{"every month on the 1st to 5th, 20th", ""},
		{"every month on the 31st", ""},
		{"every month on the 15th, 1st", ""},
		{"every month on the 1st to 31st", ""},
		{"every month on the last day", ""},
		{"every month on the last weekday", ""},
		{"every month on the nearest weekday to 1st", ""},
		{"every month on the nearest weekday to 31st", ""},
		{"every month on the nearest weekday to 15th", ""},
		{"every month on the first monday", ""},
		{"every month on the fifth friday", ""},
		{"every month on the last sunday", ""},
		{"every year on feb 29", "feb"},
		{"every year on dec 25", "dec"},
		{"every year on the 15th of march", "mar"},
		{"every year on the first monday of mar", "mar"},
		{"every year on the fifth monday of feb", "feb"},
		{"every year on the last friday of feb", "feb"},
		{"every year on the last weekday of dec", "dec"},
		{"on feb 14", "feb"},
		{"on feb 29", "feb"},
	}
	intervals = []string{
		"every 30 min from 09:00 to 17:30",
		"every 15 min from 00:00 to 23:59",
		"every 2 hours from 00:00 to 23:59",
		"every 7 hours from 00:00 to 23:59",
		"every 45 min from 09:00 to 17:00",
		"every 20 min from 09:00 to 17:40",
		"every 1 minute from 00:00 to 23:59",
		"every 120 min from 01:00 to 23:00",
		"every 2147483647 hours from 00:00 to 23:59",
		"every 5 min from 10:00 to 10:30",
		"every 4 hours from 00:00 to 20:00",
		"every 1 hour from 09:05 to 17:05",
		"every 30 min from 09:00 to 17:00",
	}
	intervalDayFilters = []string{"", " on weekday", " on weekend", " on monday, friday"}
	durings            = []string{
		"",
		"",
		" during feb",
		" during dec",
		" during jan, jul",
		" during dec, jan, feb",
		" during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
	}
)

type generatedSchedule struct {
	hron     string
	times    []int
	ownMonth string
	during   string
}

func generatedSchedules() []generatedSchedule {
	r := rng(0x2545_f491_4f6c_dd1d)
	schedules := make([]generatedSchedule, 240)
	for i := range schedules {
		during := r.pick(durings)
		if i%3 == 0 {
			filter := r.pick(intervalDayFilters)
			interval := r.pick(intervals)
			schedules[i] = generatedSchedule{
				hron:   interval + filter + during,
				times:  naiveIntervalTimes(interval),
				during: during,
			}
			continue
		}
		days := dayExpressions[r.pickIndex(len(dayExpressions))]
		times := r.pick(timeLists)
		var minutes []int
		for _, clock := range strings.Split(times, ", ") {
			minutes = append(minutes, naiveMinuteOfDay(clock))
		}
		schedules[i] = generatedSchedule{
			hron:     days[0] + " at " + times + during,
			times:    minutes,
			ownMonth: days[1],
			during:   during,
		}
	}
	return schedules
}

func naiveMinuteOfDay(clock string) int {
	hour, minute, _ := strings.Cut(clock, ":")
	h, _ := strconv.Atoi(hour)
	m, _ := strconv.Atoi(minute)
	return h*60 + m
}

func naiveIntervalTimes(interval string) []int {
	words := strings.Split(interval, " ")
	step, _ := strconv.Atoi(words[1])
	if strings.HasPrefix(words[2], "hour") {
		step *= 60
	}
	from, to := naiveMinuteOfDay(words[4]), naiveMinuteOfDay(words[6])
	var times []int
	for t := from; t <= to; t++ {
		if (t-from)%step == 0 {
			times = append(times, t)
		}
	}
	return times
}

// The reason ToCron must give, decided from the generated parts alone.
func expectedToCronFailure(generated generatedSchedule) string {
	if generated.ownMonth != "" && generated.during != "" && !strings.Contains(generated.during, generated.ownMonth) {
		return "during excludes the schedule's month"
	}
	times := slices.Compact(slices.Sorted(slices.Values(generated.times)))
	minutes, hours := map[int]bool{}, map[int]bool{}
	for _, t := range times {
		minutes[t%60], hours[t/60] = true, true
	}
	if len(minutes)*len(hours) != len(times) {
		return "times are not every combination of their minutes and hours"
	}
	return ""
}

func TestToCronIsExact(t *testing.T) {
	accepted, rejected := 0, 0
	for _, generated := range generatedSchedules() {
		hron := generated.hron
		schedule, err := ParseSchedule(hron)
		if err != nil {
			t.Fatalf("ParseSchedule(%q): %v", hron, err)
		}
		cron, err := schedule.ToCron()
		reason := expectedToCronFailure(generated)
		switch {
		case err == nil && reason == "":
		case err != nil && reason != "":
			if got, want := cronMessage(t, err), "not expressible as cron: "+reason; got != want {
				t.Fatalf("%s: %q, want %q", hron, got, want)
			}
			rejected++
			continue
		default:
			t.Fatalf("%s: ToCron gave %q, %v, expected failure %q", hron, cron, err, reason)
		}
		naive := newNaiveCron(t, cron)
		assertFiresAs(t, schedule, naive, hron+" -> "+cron)
		accepted++

		times := naive.times()
		label := hron + " -> " + cron + " -> FromCron"
		back, err := FromCron(cron)
		if len(times) > 24 && !(naive.daysCarryAnInterval() && hasEqualGaps(times)) {
			if got, want := cronMessage(t, err), expectedFromCronMessage(times); got != want {
				t.Fatalf("%s: %q, want %q", label, got, want)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%s: %v", label, err)
		}
		assertFiresAs(t, mustSchedule(t, back), naive, label)
	}
	if accepted < 60 || rejected < 20 {
		t.Fatalf("only %d generated schedules converted and %d were rejected", accepted, rejected)
	}
	t.Logf("%d generated schedules converted and %d were rejected", accepted, rejected)
}

func TestCronValuesOfAnyLengthNeverOverflow(t *testing.T) {
	longZeros := strings.Repeat("0", 10_000)
	huge := strings.Repeat("9", 10_000)
	converts := map[string]string{
		longZeros + "9 " + longZeros + "9 * * *": "every day at 09:09",
		"0 9 * * 1-5/" + huge:                    "every monday at 09:00",
		"0 9 * * 0-7/" + longZeros + "7":         "every sunday at 09:00",
	}
	for cron, want := range converts {
		if got := fromCronString(t, cron); got != want {
			t.Errorf("FromCron(%.40q...) = %q, want %q", cron, got, want)
		}
	}
	fails := map[string]string{
		"0 9 * * 1#" + huge:      "day of week ordinal must be 1-5, got " + huge,
		"0 9 " + huge + "W * *":  "day of month must be 1-31, got " + huge,
		"0 " + huge + "-1 * * *": "hour must be 0-23, got " + huge,
		"0 9 * * */" + longZeros: "day of week step must be at least 1",
		"0 9 * * -1":             "invalid day of week: -1",
		"0 9 * * +1":             "invalid day of week: +1",
	}
	for cron, want := range fails {
		if got := fromCronError(t, cron); got != want {
			t.Errorf("FromCron(%.40q...) failed with %.80q, want %.80q", cron, got, want)
		}
	}
}

func TestCronLongFieldIsParsedInLinearTime(t *testing.T) {
	items := strings.Repeat("1,", 199_999) + "1"
	if got := fromCronString(t, "0 9 "+items+" * *"); got != "every month on the 1st at 09:00" {
		t.Errorf("got %q", got)
	}
	ranges := strings.Repeat("0-59/1,", 49_999) + "0-59/1"
	if got := fromCronString(t, ranges+" 9 * * *"); got != "every 1 minute from 09:00 to 09:59" {
		t.Errorf("got %q", got)
	}
}

func TestFromCronOfEveryNMinutes(t *testing.T) {
	if got := fromCronString(t, "*/7 9 * * *"); got != "every 7 min from 09:00 to 09:56" {
		t.Errorf("got %q", got)
	}
	if got := fromCronError(t, "*/7 * * * *"); got != "not expressible in hron: 216 times a day are too many to list" {
		t.Errorf("got %q", got)
	}
}

func TestNaiveMatcherAgreesWithKnownDates(t *testing.T) {
	cases := []struct {
		cron    string
		y, m, d int
		fires   bool
		because string
	}{
		{"0 9 * 2 1#5", 2044, 2, 29, true, "the fifth Monday of a leap February"},
		{"0 9 1W * *", 2043, 8, 3, true, "Saturday the 1st moves to Monday"},
		{"0 9 31W * *", 2043, 8, 31, true, "Monday the 31st"},
		{"0 9 30W * *", 2044, 4, 29, true, "Saturday the 30th moves to Friday"},
		{"0 9 31W * *", 2044, 7, 29, true, "Sunday the 31st moves to Friday"},
		{"0 9 31W * *", 2044, 4, 30, false, "April has no 31st"},
		{"0 9 LW * *", 2044, 4, 29, true, "Friday the 29th is April's last weekday"},
		{"0 9 * * 5L", 2044, 4, 29, true, "the last Friday of April"},
		{"0 9 * * 5L", 2044, 4, 22, false, "a Friday with another after it in April"},
	}
	for _, c := range cases {
		date := time.Date(c.y, time.Month(c.m), c.d, 0, 0, 0, 0, time.UTC)
		if got := newNaiveCron(t, c.cron).firesOn(date); got != c.fires {
			t.Errorf("%s on %s: %v (%s)", c.cron, date.Format(time.DateOnly), got, c.because)
		}
	}
}

func TestToCronOfABuiltIntervalOf0StepsBy1OfItsUnitAsEvaluationDoes(t *testing.T) {
	minutes := NewScheduleData(NewIntervalRepeat(0, IntervalMin, TimeOfDay{9, 0}, TimeOfDay{9, 2}, nil))
	cron, err := ToCron(minutes)
	if err != nil || cron != "0-2 9 * * *" {
		t.Fatalf("minutes: ToCron = %q, %v", cron, err)
	}
	fires := mustSchedule(t, minutes).NextNFrom(windowStart.Add(9*time.Hour), 2)
	want := []wallTime{wallAt(windowStart, [2]int{9, 1}), wallAt(windowStart, [2]int{9, 2})}
	if len(fires) != 2 || wallOf(fires[0]) != want[0] || wallOf(fires[1]) != want[1] {
		t.Fatalf("minutes: fires at %v, want %v", fires, want)
	}

	hours := NewScheduleData(NewIntervalRepeat(0, IntervalHours, TimeOfDay{9, 0}, TimeOfDay{10, 0}, nil))
	cron, err = ToCron(hours)
	if err != nil || cron != "0 9-10 * * *" {
		t.Fatalf("hours: ToCron = %q, %v", cron, err)
	}
	fires = mustSchedule(t, hours).NextNFrom(windowStart.Add(8*time.Hour), 3)
	want = []wallTime{
		wallAt(windowStart, [2]int{9, 0}),
		wallAt(windowStart, [2]int{10, 0}),
		wallAt(windowStart.AddDate(0, 0, 1), [2]int{9, 0}),
	}
	if len(fires) != 3 || wallOf(fires[0]) != want[0] || wallOf(fires[1]) != want[1] || wallOf(fires[2]) != want[2] {
		t.Fatalf("hours: fires at %v, want %v", fires, want)
	}
}

func TestToCronOfABuiltScheduleWithoutTimesFails(t *testing.T) {
	built := []ScheduleExpr{
		NewDayRepeat(1, NewDayFilterEvery(), nil),
		NewIntervalRepeat(1, IntervalHours, TimeOfDay{9, 0}, TimeOfDay{8, 0}, nil),
	}
	for _, expr := range built {
		_, err := ToCron(NewScheduleData(expr))
		if got := cronMessage(t, err); got != "not expressible as cron: schedule has no times" {
			t.Errorf("%+v: %q", expr, got)
		}
	}
}

func TestToCronOfABuiltScheduleWithoutDaysFails(t *testing.T) {
	nine := []TimeOfDay{{9, 0}}
	noDays := NewDayFilterDays(nil)
	built := []ScheduleExpr{
		NewDayRepeat(1, noDays, nine),
		NewWeekRepeat(1, nil, nine),
		NewMonthRepeat(1, NewDaysTarget(nil), nine),
		NewMonthRepeat(1, NewDaysTarget([]DayOfMonthSpec{NewDayRange(9, 5)}), nine),
		NewIntervalRepeat(1, IntervalHours, TimeOfDay{9, 0}, TimeOfDay{17, 0}, &noDays),
	}
	for _, expr := range built {
		_, err := ToCron(NewScheduleData(expr))
		if got := cronMessage(t, err); got != "not expressible as cron: schedule has no days" {
			t.Errorf("%+v: %q", expr, got)
		}
	}
}

func TestToCronReasonsAroundNoDaysAndNoTimesFollowTheOrder(t *testing.T) {
	withDuring := func(expr ScheduleExpr, during ...MonthName) *ScheduleData {
		data := NewScheduleData(expr)
		data.During = during
		return data
	}
	yearlyWithoutTimes := NewYearRepeat(1, NewYearDateTarget(Dec, 25), nil)
	cases := []struct {
		data *ScheduleData
		want string
	}{
		{withDuring(NewWeekRepeat(2, nil, nil)), "multi-week repeats not supported"},
		{withDuring(NewMonthRepeat(1, NewNearestWeekdayTarget(1, NearestNext), nil)), "directional nearest weekday not supported"},
		{withDuring(NewWeekRepeat(1, nil, nil), Mar), "schedule has no days"},
		{withDuring(yearlyWithoutTimes, Jan), "during excludes the schedule's month"},
		{withDuring(yearlyWithoutTimes), "schedule has no times"},
	}
	for _, c := range cases {
		_, err := ToCron(c.data)
		if got := cronMessage(t, err); got != "not expressible as cron: "+c.want {
			t.Errorf("%+v: %q, want %q", c.data.Expr, got, c.want)
		}
	}
}

func TestToCronOfAnUnknownKindFailsWithoutPanicking(t *testing.T) {
	built := []ScheduleExpr{
		{Kind: ScheduleExprKind(99)},
		{Kind: ScheduleExprKindMonth, MonthTarget: MonthTarget{Kind: MonthTargetKind(99)}, Times: []TimeOfDay{{9, 0}}},
		{Kind: ScheduleExprKindYear, YearTarget: YearTarget{Kind: YearTargetKind(99)}, Times: []TimeOfDay{{9, 0}}},
	}
	for _, expr := range built {
		_, err := ToCron(NewScheduleData(expr))
		if got := cronMessage(t, err); got != "invalid schedule: unknown expression or target kind" {
			t.Errorf("%+v: %q", expr, got)
		}
	}
}
