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
	t, err := time.Parse(time.RFC3339, parts[1])
	if err != nil {
		panic(err)
	}
	return t.In(loc)
}

func formatZoned(t time.Time) string {
	return t.Format("2006-01-02T15:04:05-07:00") + "[" + t.Location().String() + "]"
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
			if left == 0 || !yield(t) {
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
