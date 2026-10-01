package hron

import (
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

const (
	fuzzInputs = 6000
	fuzzSeed   = 0x60E4_404E

	fuzzWhat = `'every' or 'on'` +
		`|'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number` +
		`|a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)` +
		`|'at'|a time \(HH:MM\)|'from'|'to'` +
		`|'day', 'weekday', 'weekend' or a day name` +
		`|'on'|a day name|'the'` +
		`|a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'` +
		`|'day', 'weekday' or a day name` +
		`|'nearest'|'weekday'|a day such as 15th` +
		`|a month name or 'the'` +
		`|a day such as 15th, 'last' or an ordinal such as 'first'` +
		`|'weekday' or a day name` +
		`|'of'|a month name|a day number` +
		`|a date \(YYYY-MM-DD, or a month and day\)|a date \(YYYY-MM-DD\)|a timezone`
	fuzzMonth = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
	fuzzDay   = `[0-9]+(?i:st|nd|rd|th)?`
	fuzzTime  = `[0-9]{1,2}:[0-9]{2}`

	tokenSeparators = " \t\r\n"
)

var fuzzClauseOrder = []string{"except", "until", "starting", "during", "in"}

type fuzzFailure struct {
	input   string
	span    Span
	spanned string
}

type fuzzCheck func(groups map[string]string, f fuzzFailure) error

type fuzzTemplate struct {
	kind  ErrorKind
	regex *regexp.Regexp
	check fuzzCheck
}

func ensure(holds bool, problem func() string) error {
	if holds {
		return nil
	}
	return errors.New(problem())
}

// Saturates, since a digit run can be thousands of digits long.
func fuzzValue(text string) uint64 {
	var n uint64
	for i := 0; i < len(text) && isDigit(text[i]); i++ {
		digit := uint64(text[i] - '0')
		if n > (^uint64(0)-digit)/10 {
			return ^uint64(0)
		}
		n = n*10 + digit
	}
	return n
}

func asciiUpper(s string) string {
	out := []byte(s)
	for i, b := range out {
		if b >= 'a' && b <= 'z' {
			out[i] = b - ('a' - 'A')
		}
	}
	return string(out)
}

// Counts each invalid UTF-8 byte as one code point, as spans do.
func byteOffset(s string, n int) int {
	offset := 0
	for ; n > 0 && offset < len(s); n-- {
		_, size := utf8.DecodeRuneInString(s[offset:])
		offset += size
	}
	return offset
}

func noCheck(map[string]string, fuzzFailure) error { return nil }

// From spec/README.md, "Lex errors" and "Parse errors". A span group must
// equal the spanned text; every other group is read by its template's check.
func fuzzTemplates() []fuzzTemplate {
	template := func(kind ErrorKind, pattern string, check fuzzCheck) fuzzTemplate {
		return fuzzTemplate{kind, regexp.MustCompile(pattern), check}
	}
	return []fuzzTemplate{
		template(ErrorKindLex, `^unexpected character '(?P<span>[!-&(-~])'$`, func(_ map[string]string, f fuzzFailure) error {
			c := f.spanned[0]
			return ensure(!isAlphanumeric(c) && c != ',', func() string {
				return fmt.Sprintf("'%c' starts a token, so it is never unexpected", c)
			})
		}),
		template(ErrorKindLex, `^unexpected character U\+(?P<code>[0-9A-F]{4,})$`, func(g map[string]string, f fuzzFailure) error {
			shown, err := strconv.ParseUint(g["code"], 16, 32)
			quotable := shown >= 0x21 && shown <= 0x7e && shown != 0x27
			c, size := utf8.DecodeRuneInString(f.spanned)
			return ensure(err == nil && uint64(c) == shown && size == len(f.spanned) && !quotable, func() string {
				return fmt.Sprintf("U+%s does not describe %q", g["code"], f.spanned)
			})
		}),
		template(ErrorKindLex, `^unknown keyword '(?P<span>[A-Za-z][A-Za-z0-9_]*)'$`, noCheck),
		template(ErrorKindLex, `^time must be H:MM or HH:MM, got (?P<span>(?P<hour>[0-9]+):(?P<minute>[0-9]*))$`, func(g map[string]string, _ fuzzFailure) error {
			hour, minute := g["hour"], g["minute"]
			return ensure(len(hour) < 1 || len(hour) > 2 || len(minute) != 2, func() string {
				return fmt.Sprintf("%s:%s is H:MM or HH:MM", hour, minute)
			})
		}),
		template(ErrorKindLex, `^time must be 00:00-23:59, got (?P<span>(?P<hour>[0-9]{1,2}):(?P<minute>[0-9]{2}))$`, func(g map[string]string, _ fuzzFailure) error {
			hour, minute := fuzzValue(g["hour"]), fuzzValue(g["minute"])
			return ensure(hour > 23 || minute > 59, func() string { return fmt.Sprintf("%d:%d is in range", hour, minute) })
		}),
		template(ErrorKindLex, `^number must be at most 2147483647$`, func(_ map[string]string, f fuzzFailure) error {
			digits := f.spanned != "" && strings.Trim(f.spanned, "0123456789") == ""
			return ensure(digits && fuzzValue(f.spanned) > 2147483647, func() string {
				return fmt.Sprintf("%q is not digits above 2147483647", f.spanned)
			})
		}),
		template(ErrorKindParse, `^empty expression$`, func(_ map[string]string, f fuzzFailure) error {
			blank := strings.Trim(f.input, tokenSeparators) == ""
			return ensure(blank && f.span == Span{0, 0}, func() string {
				return fmt.Sprintf("empty expression with span %v for %q", f.span, f.input)
			})
		}),
		template(ErrorKindParse, `^expected (?:`+fuzzWhat+`), got (?:'(?P<span>.+)'|(?P<end>end of input))$`, func(g map[string]string, f fuzzFailure) error {
			if _, atEnd := g["end"]; !atEnd {
				return nil
			}
			end := utf8.RuneCountInString(strings.TrimRight(f.input, tokenSeparators))
			return ensure(f.span == Span{end, end}, func() string {
				return fmt.Sprintf("end of input at %v, expected %d..%d", f.span, end, end)
			})
		}),
		template(ErrorKindParse, `^interval must be 1-2147483647, got (?P<span>[0-9]+)$`, func(_ map[string]string, f fuzzFailure) error {
			return ensure(fuzzValue(f.spanned) == 0, func() string { return fmt.Sprintf("interval %s is valid", f.spanned) })
		}),
		template(ErrorKindParse, `^day must be 1-31, got (?P<span>`+fuzzDay+`)$`, func(_ map[string]string, f fuzzFailure) error {
			day := fuzzValue(f.spanned)
			return ensure(day == 0 || day > 31, func() string { return fmt.Sprintf("day %d is within 1-31", day) })
		}),
		template(ErrorKindParse, `^day must be 1-(?P<max>[0-9]+) for (?P<month>`+fuzzMonth+`), got (?P<span>`+fuzzDay+`)$`, func(g map[string]string, f fuzzFailure) error {
			month := g["month"]
			length := uint64(31)
			switch month {
			case "feb":
				length = 29
			case "apr", "jun", "sep", "nov":
				length = 30
			}
			maxDay, day := fuzzValue(g["max"]), fuzzValue(f.spanned)
			return ensure(maxDay == length && day > maxDay && day <= 31, func() string {
				return fmt.Sprintf("day %d against 1-%d for %s", day, maxDay, month)
			})
		}),
		template(ErrorKindParse, `^day range must not run backwards: (?P<a>`+fuzzDay+`) to (?P<b>`+fuzzDay+`)$`, func(g map[string]string, f fuzzFailure) error {
			a, b := g["a"], g["b"]
			spansBoth := strings.HasPrefix(f.spanned, a) && strings.HasSuffix(f.spanned, b)
			return ensure(spansBoth && fuzzValue(a) > fuzzValue(b), func() string {
				return fmt.Sprintf("%s to %s against the span %q", a, b, f.spanned)
			})
		}),
		template(ErrorKindParse, `^time window must not run backwards: (?P<from>`+fuzzTime+`) to (?P<to>`+fuzzTime+`) \(a window cannot cross midnight\)$`, func(g map[string]string, f fuzzFailure) error {
			from, to := g["from"], g["to"]
			minutes := func(t string) uint64 {
				hour, minute, _ := strings.Cut(t, ":")
				return fuzzValue(hour)*60 + fuzzValue(minute)
			}
			spansBoth := strings.HasPrefix(f.spanned, from) && strings.HasSuffix(f.spanned, to)
			return ensure(spansBoth && minutes(from) > minutes(to), func() string {
				return fmt.Sprintf("%s to %s against the span %q", from, to, f.spanned)
			})
		}),
		template(ErrorKindParse, `^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?P<span>[0-9]{4}-[0-9]{2}-[0-9]{2})$`, func(_ map[string]string, f fuzzFailure) error {
			date, err := time.Parse("2006-01-02", f.spanned)
			return ensure(err != nil || date.Year() < 1, func() string { return f.spanned + " is a calendar date" })
		}),
		template(ErrorKindParse, `^timezone must be UTC or an Area/Location name such as America/New_York, got (?P<span>.+)$`, noCheck),
		template(ErrorKindParse, `^duplicate '(?P<keyword>except|until|starting|during|in)' clause$`, func(g map[string]string, f fuzzFailure) error {
			return ensure(g["keyword"] == asciiLower(f.spanned), func() string {
				return fmt.Sprintf("duplicate '%s' but the span holds %q", g["keyword"], f.spanned)
			})
		}),
		template(ErrorKindParse, `^'(?P<keyword>[a-z]+)' must come before '(?P<last>[a-z]+)'$`, func(g map[string]string, f fuzzFailure) error {
			keyword, last := g["keyword"], g["last"]
			order := func(kw string) int {
				for i, k := range fuzzClauseOrder {
					if k == kw {
						return i
					}
				}
				return -1
			}
			earlier := order(keyword) >= 0 && order(last) >= 0 && order(keyword) < order(last)
			return ensure(earlier && keyword == asciiLower(f.spanned), func() string {
				return fmt.Sprintf("'%s' before '%s' with the span %q", keyword, last, f.spanned)
			})
		}),
		template(ErrorKindParse, `^unexpected '(?P<span>.+)' after the schedule$`, noCheck),
		template(ErrorKindParse, `^until (?P<month>`+fuzzMonth+`) (?P<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date$`, func(g map[string]string, f fuzzFailure) error {
			words := strings.FieldsFunc(f.spanned, func(r rune) bool { return strings.ContainsRune(tokenSeparators, r) })
			endsAtDay := f.spanned != "" && strings.TrimRight(f.spanned, tokenSeparators) == f.spanned
			matchesMessage := endsAtDay && len(words) == 3 &&
				asciiLower(words[0]) == "until" &&
				strings.HasPrefix(asciiLower(words[1]), g["month"]) &&
				isDigit(words[2][0]) &&
				strconv.FormatUint(fuzzValue(words[2]), 10) == g["day"]
			return ensure(matchesMessage, func() string {
				return fmt.Sprintf("the span %q is not 'until %s %s'", f.spanned, g["month"], g["day"])
			})
		}),
	}
}

var fuzzFragments = []string{
	"every", "on", "at", "from", "to", "in", "IN", "of", "the", "last", "except", "until",
	"starting", "during", "nearest", "next", "previous", "day", "Days", "weekdays", "weekend",
	"week", "month", "years", "min", "hrs", "monday", "FRI", "jan", "february", "first", "fifth",
	"0", "1", "00", "15th", "31ST", "2nd", "2147483647", "2147483648", "99999999999999999999",
	"09:00", "9:5", "24:00", "9:", "17:30", "2026-02-28", "2026-02-30", "0000-01-01", "12026-03-15",
	",", ":", "-", "/", "'", "\"", "#", "~", "_", "UTC", "America/New_York", "Nope/Zone",
	"Europe/\u0130stanbul", "\u00e9", "e\u0301", "\u212a", "\u00a0", "\u2028", "\ufeff", "\uff10",
	"\U0001f600", "\U0010ffff", "\U0001d7d8", "\x00", "\v", "\f", "\x7f", "\x1b",
	// Go strings can hold invalid UTF-8, which the spec counts one code point per byte.
	"\xff", "\xed\xa0\x80",
}

var fuzzSeparators = []string{"", " ", " ", " ", "  ", "\t", "\r\n", "\n"}

var fuzzClauses = []string{
	"except dec 25",
	"except 2026-12-25, jan 1",
	"until 2027-12-31",
	"until dec 31",
	"starting 2026-01-01",
	"during jan, jul",
	"in UTC",
	"IN America/New_York",
}

type splitMix64 uint64

// SplitMix64: a fixed seed gives the same inputs on every platform.
func (r *splitMix64) next() uint64 {
	*r += 0x9E3779B97F4A7C15
	z := uint64(*r)
	z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ^ (z >> 27)) * 0x94D049BB133111EB
	return z ^ (z >> 31)
}

func (r *splitMix64) below(n int) int {
	return int(r.next() % uint64(n))
}

func (r *splitMix64) pick(items []string) string {
	return items[r.below(len(items))]
}

func fuzzCorpus(t *testing.T) []string {
	spec := loadSpec(t)
	var corpus []string
	addInputs := func(raw json.RawMessage) {
		var section struct {
			Tests []struct {
				Input string `json:"input"`
			} `json:"tests"`
		}
		if json.Unmarshal(raw, &section) == nil {
			for _, tc := range section.Tests {
				corpus = append(corpus, tc.Input)
			}
		}
	}
	for _, raw := range spec.Parse {
		addInputs(raw)
	}
	addInputs(spec.ParseErrors)
	return corpus
}

func randomText(r *splitMix64) string {
	var out strings.Builder
	for range r.below(12) + 1 {
		out.WriteString(r.pick(fuzzSeparators))
		out.WriteString(r.pick(fuzzFragments))
	}
	return out.String()
}

func mutateInput(r *splitMix64, input string) string {
	words := strings.Split(input, " ")
	i := r.below(len(words))
	switch r.below(7) {
	case 0:
		words = append(words[:i], words[i+1:]...)
	case 1:
		j := r.below(len(words))
		words[i], words[j] = words[j], words[i]
	case 2:
		at := r.below(len(words) + 1)
		words = append(words[:at], append([]string{words[i]}, words[at:]...)...)
	case 3:
		return input[:byteOffset(input, r.below(utf8.RuneCountInString(input)+1))]
	case 4:
		words[i] = asciiUpper(words[i])
	case 5:
		words[i] = r.pick(fuzzFragments)
	default:
		fragment := r.pick(fuzzFragments)
		at := byteOffset(words[i], r.below(utf8.RuneCountInString(words[i])+1))
		words[i] = words[i][:at] + fragment + words[i][at:]
	}
	return strings.Join(words, " ")
}

func withClauses(r *splitMix64, input string) string {
	for range r.below(4) + 1 {
		input += " " + r.pick(fuzzClauses)
	}
	return input
}

func generateInput(r *splitMix64, corpus []string) string {
	switch r.below(4) {
	case 0:
		return randomText(r)
	case 1:
		return withClauses(r, corpus[r.below(len(corpus))])
	default:
		input := corpus[r.below(len(corpus))]
		for range r.below(4) {
			input = mutateInput(r, input)
		}
		return input
	}
}

func checkSpecError(input string, err error, templates []fuzzTemplate) (int, error) {
	var hronErr *HronError
	if !errors.As(err, &hronErr) || (hronErr.Kind != ErrorKindLex && hronErr.Kind != ErrorKindParse) {
		return 0, fmt.Errorf("neither lex nor parse: %#v", err)
	}
	if Validate(input) {
		return 0, errors.New("validate is true")
	}
	if hronErr.Input != input {
		return 0, fmt.Errorf("error input is %q", hronErr.Input)
	}
	span := hronErr.Span
	length := utf8.RuneCountInString(input)
	if span == nil || span.Start < 0 || span.Start > span.End || span.End > length {
		return 0, fmt.Errorf("span %v outside 0..=%d", span, length)
	}
	failure := fuzzFailure{input, *span, input[byteOffset(input, span.Start):byteOffset(input, span.End)]}

	index, groups := -1, map[string]string{}
	for i, template := range templates {
		if template.kind != hronErr.Kind {
			continue
		}
		if match := template.regex.FindStringSubmatchIndex(hronErr.Message); match != nil {
			index = i
			for g, name := range template.regex.SubexpNames() {
				if name != "" && match[2*g] >= 0 {
					groups[name] = hronErr.Message[match[2*g]:match[2*g+1]]
				}
			}
			break
		}
	}
	if index < 0 {
		return 0, fmt.Errorf("%s message %q matches no template", hronErr.Kind, hronErr.Message)
	}
	if echoed, ok := groups["span"]; ok && echoed != failure.spanned {
		return 0, fmt.Errorf("message echoes %q but the span holds %q", echoed, failure.spanned)
	}
	if err := templates[index].check(groups, failure); err != nil {
		return 0, err
	}

	expectedSuggestion := ""
	if strings.HasPrefix(hronErr.Message, "until ") {
		expectedSuggestion = fmt.Sprintf("until %s %s starting YYYY-MM-DD", groups["month"], groups["day"])
	}
	if hronErr.Suggestion != expectedSuggestion {
		return 0, fmt.Errorf("suggestion %q, expected %q", hronErr.Suggestion, expectedSuggestion)
	}

	rich := hronErr.DisplayRich()
	if strings.Count(rich, "\n") != 2 || !strings.HasPrefix(rich, "error: "+hronErr.Message+"\n") {
		return 0, fmt.Errorf("DisplayRich is not three lines: %q", rich)
	}
	return index, nil
}

func parseRecovering(input string) (panicked any, err error) {
	defer func() { panicked = recover() }()
	_, err = ParseSchedule(input)
	return nil, err
}

func TestGeneratedInputsFailOnlyWithSpecErrors(t *testing.T) {
	templates := fuzzTemplates()
	corpus := fuzzCorpus(t)
	rng := splitMix64(fuzzSeed)
	hits := make([]int, len(templates))
	parsed := 0
	var failures []string

	for range fuzzInputs {
		input := generateInput(&rng, corpus)
		panicked, err := parseRecovering(input)
		switch {
		case panicked != nil:
			failures = append(failures, fmt.Sprintf("%q: parse panicked: %v", input, panicked))
		case err == nil:
			parsed++
		default:
			index, problem := checkSpecError(input, err, templates)
			if problem != nil {
				failures = append(failures, fmt.Sprintf("%q: %v", input, problem))
			} else {
				hits[index]++
			}
		}
	}

	if len(failures) > 0 {
		t.Errorf("%d failures, first ones:\n%s", len(failures), strings.Join(failures[:min(len(failures), 20)], "\n"))
	}
	if parsed <= fuzzInputs/20 {
		t.Errorf("only %d inputs parsed; the generator has drifted", parsed)
	}
	for i, template := range templates {
		if hits[i] == 0 {
			t.Errorf("no input produced the template %s", template.regex)
		}
	}
}
