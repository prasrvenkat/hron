package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"iter"
	"os"
	"regexp"
	"slices"
	"time"

	hron "github.com/simpllyf/hron/go/v2"
)

type testCase struct {
	ID       string `json:"id"`
	Op       string `json:"op"`
	Expr     string `json:"expr"`
	Now      string `json:"now"`
	Datetime string `json:"datetime"`
	From     string `json:"from"`
	To       string `json:"to"`
	N        int    `json:"n"`
}

var zoned = regexp.MustCompile(`^(.+)\[(.+)\]$`)

var offsetWithSeconds = regexp.MustCompile(`[+-]\d\d:\d\d:\d\d$`)

var locations = map[string]*time.Location{}

func location(name string) *time.Location {
	if loc, ok := locations[name]; ok {
		return loc
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	locations[name] = loc
	return loc
}

func parseZoned(s string) time.Time {
	parts := zoned.FindStringSubmatch(s)
	loc := location(parts[2])
	layout := time.RFC3339
	if offsetWithSeconds.MatchString(parts[1]) {
		layout = "2006-01-02T15:04:05-07:00:00"
	}
	t, err := time.Parse(layout, parts[1])
	if err != nil {
		panic(err)
	}
	return t.In(loc)
}

// Go's -07:00 layout drops an offset's seconds, and -07:00:00 writes Africa/Accra's -00:00:52 as
// +00:00:-52.
func formatZoned(t time.Time) string {
	_, offset := t.Zone()
	sign := '+'
	if offset < 0 {
		sign, offset = '-', -offset
	}
	zone := fmt.Sprintf("%c%02d:%02d", sign, offset/3600, offset/60%60)
	if offset%60 != 0 {
		zone += fmt.Sprintf(":%02d", offset%60)
	}
	return t.Format("2006-01-02T15:04:05") + zone + "[" + t.Location().String() + "]"
}

func formatOrNil(t *time.Time) any {
	if t == nil {
		return nil
	}
	return formatZoned(*t)
}

func formatAll(times iter.Seq[time.Time]) []string {
	out := []string{}
	for t := range times {
		out = append(out, formatZoned(t))
	}
	return out
}

func take(times iter.Seq[time.Time], n int) iter.Seq[time.Time] {
	return func(yield func(time.Time) bool) {
		left := n
		for t := range times {
			if left <= 0 || !yield(t) {
				return
			}
			left--
		}
	}
}

func evaluate(c testCase) (any, error) {
	if c.Op == "fromCron" {
		s, err := hron.FromCronExpr(c.Expr)
		if err != nil {
			return nil, err
		}
		return s.String(), nil
	}
	s, err := hron.ParseSchedule(c.Expr)
	if err != nil {
		return nil, err
	}
	switch c.Op {
	case "parse":
		return s.String(), nil
	case "toCron":
		return s.ToCron()
	case "next":
		return formatOrNil(s.NextFrom(parseZoned(c.Now))), nil
	case "nextN":
		return formatAll(slices.Values(s.NextNFrom(parseZoned(c.Now), c.N))), nil
	case "prev":
		return formatOrNil(s.PreviousFrom(parseZoned(c.Now))), nil
	case "matches":
		return s.Matches(parseZoned(c.Datetime)), nil
	case "between":
		return formatAll(s.Between(parseZoned(c.From), parseZoned(c.To))), nil
	case "occurrences":
		return formatAll(take(s.Occurrences(parseZoned(c.From)), c.N)), nil
	}
	panic("unknown op " + c.Op)
}

func details(e *hron.HronError) map[string]any {
	var span, suggestion any
	if e.Span != nil {
		span = []int{e.Span.Start, e.Span.End}
	}
	if e.Suggestion != "" {
		suggestion = e.Suggestion
	}
	return map[string]any{"kind": string(e.Kind), "message": e.Message, "span": span, "suggestion": suggestion}
}

func run(c testCase) (outcome map[string]any) {
	defer func() {
		if r := recover(); r != nil {
			outcome = map[string]any{"ok": false, "error": map[string]any{"kind": "crash", "message": fmt.Sprint(r)}}
		}
	}()
	result, err := evaluate(c)
	var hronErr *hron.HronError
	switch {
	case errors.As(err, &hronErr):
		return map[string]any{"ok": false, "error": details(hronErr)}
	case err != nil:
		return map[string]any{"ok": false, "error": map[string]any{"kind": "crash", "message": err.Error()}}
	}
	return map[string]any{"ok": true, "result": result}
}

func main() {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(nil, 1<<24)
	out := json.NewEncoder(os.Stdout)
	for scanner.Scan() {
		var c testCase
		if err := json.Unmarshal(scanner.Bytes(), &c); err != nil {
			panic(err)
		}
		start := time.Now()
		outcome := run(c)
		outcome["micros"] = time.Since(start).Microseconds()
		outcome["id"] = c.ID
		if err := out.Encode(outcome); err != nil {
			panic(err)
		}
	}
}
