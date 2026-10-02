package hron

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

type tokenKind int

const (
	tokenEvery tokenKind = iota
	tokenOn
	tokenAt
	tokenFrom
	tokenTo
	tokenIn
	tokenOf
	tokenThe
	tokenLast
	tokenExcept
	tokenUntil
	tokenStarting
	tokenDuring
	tokenYear
	tokenDay
	tokenWeekday
	tokenWeekend
	tokenWeeks
	tokenMonth
	tokenDayName
	tokenMonthName
	tokenOrdinal
	tokenIntervalUnit
	tokenNumber
	tokenOrdinalNumber
	tokenTime
	tokenISODate
	tokenComma
	tokenTimezone
	tokenNearest
	tokenNext
	tokenPrevious
)

type token struct {
	Kind tokenKind
	Span Span

	DayNameVal   Weekday
	MonthNameVal MonthName
	OrdinalVal   OrdinalPosition
	UnitVal      IntervalUnit
	NumberVal    int
	TimeHour     int
	TimeMinute   int
	ISODateVal   string
	TimezoneVal  string
}

type lexer struct {
	input string
	pos   int
}

// Token spans count bytes, unlike the code points of an error's Span.
func tokenize(input string) ([]token, error) {
	l := &lexer{input: input}
	return l.tokenize()
}

func (l *lexer) tokenize() ([]token, error) {
	var tokens []token
	for {
		l.advanceWhile(isWhitespace)
		if l.pos >= len(l.input) {
			return tokens, nil
		}
		start := l.pos
		c := l.input[l.pos]
		var tok token
		var err error
		switch {
		case len(tokens) > 0 && tokens[len(tokens)-1].Kind == tokenIn:
			l.advanceWhile(func(b byte) bool { return !isWhitespace(b) })
			tok = token{Kind: tokenTimezone, TimezoneVal: l.input[start:l.pos]}
		case c == ',':
			l.pos++
			tok = token{Kind: tokenComma}
		case isAlpha(c):
			tok, err = l.word(start)
		case isDigit(c):
			tok, err = l.digits(start)
		default:
			return nil, l.unexpectedCharacter(start)
		}
		if err != nil {
			return nil, err
		}
		tok.Span = Span{start, l.pos}
		tokens = append(tokens, tok)
	}
}

func (l *lexer) advanceWhile(matches func(byte) bool) {
	for l.pos < len(l.input) && matches(l.input[l.pos]) {
		l.pos++
	}
}

func (l *lexer) error(message string, start int) error {
	return LexError(message, codePointSpan(l.input, start, l.pos), l.input)
}

func (l *lexer) word(start int) (token, error) {
	l.advanceWhile(func(b byte) bool { return isAlphanumeric(b) || b == '_' })
	text := l.input[start:l.pos]
	tok, ok := keywordMap[asciiLower(text)]
	if !ok {
		return token{}, l.error("unknown keyword '"+text+"'", start)
	}
	return tok, nil
}

func (l *lexer) digits(start int) (token, error) {
	l.advanceWhile(isDigit)
	digits := l.input[start:l.pos]
	rest := l.input[l.pos:]
	if len(digits) == 4 && isISODateTail(rest) {
		l.pos += len("-MM-DD")
		return token{Kind: tokenISODate, ISODateVal: l.input[start:l.pos]}, nil
	}
	if strings.HasPrefix(rest, ":") {
		return l.time(start)
	}
	value, ok := numberValue(digits)
	if !ok {
		return token{}, l.error("number must be at most 2147483647", start)
	}
	if isOrdinalSuffix(rest) {
		l.pos += 2
		return token{Kind: tokenOrdinalNumber, NumberVal: value}, nil
	}
	return token{Kind: tokenNumber, NumberVal: value}, nil
}

func (l *lexer) time(start int) (token, error) {
	colon := l.pos
	l.pos++
	l.advanceWhile(isDigit)
	hour, minute, text := l.input[start:colon], l.input[colon+1:l.pos], l.input[start:l.pos]
	if len(hour) > 2 || len(minute) != 2 {
		return token{}, l.error("time must be H:MM or HH:MM, got "+text, start)
	}
	h, m := twoDigitValue(hour), twoDigitValue(minute)
	if h > 23 || m > 59 {
		return token{}, l.error("time must be 00:00-23:59, got "+text, start)
	}
	return token{Kind: tokenTime, TimeHour: h, TimeMinute: m}, nil
}

func (l *lexer) unexpectedCharacter(start int) error {
	c, size := utf8.DecodeRuneInString(l.input[start:])
	shown := fmt.Sprintf("U+%04X", c)
	// `'` is excluded because `'''` would not read as a quoted character.
	if c >= '!' && c <= '~' && c != '\'' {
		shown = "'" + string(c) + "'"
	}
	return LexError("unexpected character "+shown, codePointSpan(l.input, start, start+size), l.input)
}

func isISODateTail(rest string) bool {
	return len(rest) >= 6 && rest[0] == '-' && isDigit(rest[1]) && isDigit(rest[2]) &&
		rest[3] == '-' && isDigit(rest[4]) && isDigit(rest[5])
}

// Checked before each digit is added, so n never exceeds math.MaxInt32 and cannot overflow
// even where int is 32 bits.
func numberValue(digits string) (int, bool) {
	n := 0
	for i := 0; i < len(digits); i++ {
		digit := int(digits[i] - '0')
		if n > (math.MaxInt32-digit)/10 {
			return 0, false
		}
		n = n*10 + digit
	}
	return n, true
}

func twoDigitValue(digits string) int {
	n := 0
	for i := 0; i < len(digits); i++ {
		n = n*10 + int(digits[i]-'0')
	}
	return n
}

func isOrdinalSuffix(rest string) bool {
	if len(rest) < 2 {
		return false
	}
	switch asciiLower(rest[:2]) {
	case "st", "nd", "rd", "th":
		return true
	}
	return false
}

var keywordMap = map[string]token{
	"every":    {Kind: tokenEvery},
	"on":       {Kind: tokenOn},
	"at":       {Kind: tokenAt},
	"from":     {Kind: tokenFrom},
	"to":       {Kind: tokenTo},
	"in":       {Kind: tokenIn},
	"of":       {Kind: tokenOf},
	"the":      {Kind: tokenThe},
	"last":     {Kind: tokenLast},
	"except":   {Kind: tokenExcept},
	"until":    {Kind: tokenUntil},
	"starting": {Kind: tokenStarting},
	"during":   {Kind: tokenDuring},
	"year":     {Kind: tokenYear},
	"years":    {Kind: tokenYear},
	"day":      {Kind: tokenDay},
	"days":     {Kind: tokenDay},
	"weekday":  {Kind: tokenWeekday},
	"weekdays": {Kind: tokenWeekday},
	"weekend":  {Kind: tokenWeekend},
	"weekends": {Kind: tokenWeekend},
	"weeks":    {Kind: tokenWeeks},
	"week":     {Kind: tokenWeeks},
	"month":    {Kind: tokenMonth},
	"months":   {Kind: tokenMonth},

	"monday":    {Kind: tokenDayName, DayNameVal: Monday},
	"mon":       {Kind: tokenDayName, DayNameVal: Monday},
	"tuesday":   {Kind: tokenDayName, DayNameVal: Tuesday},
	"tue":       {Kind: tokenDayName, DayNameVal: Tuesday},
	"wednesday": {Kind: tokenDayName, DayNameVal: Wednesday},
	"wed":       {Kind: tokenDayName, DayNameVal: Wednesday},
	"thursday":  {Kind: tokenDayName, DayNameVal: Thursday},
	"thu":       {Kind: tokenDayName, DayNameVal: Thursday},
	"friday":    {Kind: tokenDayName, DayNameVal: Friday},
	"fri":       {Kind: tokenDayName, DayNameVal: Friday},
	"saturday":  {Kind: tokenDayName, DayNameVal: Saturday},
	"sat":       {Kind: tokenDayName, DayNameVal: Saturday},
	"sunday":    {Kind: tokenDayName, DayNameVal: Sunday},
	"sun":       {Kind: tokenDayName, DayNameVal: Sunday},

	"january":   {Kind: tokenMonthName, MonthNameVal: Jan},
	"jan":       {Kind: tokenMonthName, MonthNameVal: Jan},
	"february":  {Kind: tokenMonthName, MonthNameVal: Feb},
	"feb":       {Kind: tokenMonthName, MonthNameVal: Feb},
	"march":     {Kind: tokenMonthName, MonthNameVal: Mar},
	"mar":       {Kind: tokenMonthName, MonthNameVal: Mar},
	"april":     {Kind: tokenMonthName, MonthNameVal: Apr},
	"apr":       {Kind: tokenMonthName, MonthNameVal: Apr},
	"may":       {Kind: tokenMonthName, MonthNameVal: May},
	"june":      {Kind: tokenMonthName, MonthNameVal: Jun},
	"jun":       {Kind: tokenMonthName, MonthNameVal: Jun},
	"july":      {Kind: tokenMonthName, MonthNameVal: Jul},
	"jul":       {Kind: tokenMonthName, MonthNameVal: Jul},
	"august":    {Kind: tokenMonthName, MonthNameVal: Aug},
	"aug":       {Kind: tokenMonthName, MonthNameVal: Aug},
	"september": {Kind: tokenMonthName, MonthNameVal: Sep},
	"sep":       {Kind: tokenMonthName, MonthNameVal: Sep},
	"october":   {Kind: tokenMonthName, MonthNameVal: Oct},
	"oct":       {Kind: tokenMonthName, MonthNameVal: Oct},
	"november":  {Kind: tokenMonthName, MonthNameVal: Nov},
	"nov":       {Kind: tokenMonthName, MonthNameVal: Nov},
	"december":  {Kind: tokenMonthName, MonthNameVal: Dec},
	"dec":       {Kind: tokenMonthName, MonthNameVal: Dec},

	"first":  {Kind: tokenOrdinal, OrdinalVal: First},
	"second": {Kind: tokenOrdinal, OrdinalVal: Second},
	"third":  {Kind: tokenOrdinal, OrdinalVal: Third},
	"fourth": {Kind: tokenOrdinal, OrdinalVal: Fourth},
	"fifth":  {Kind: tokenOrdinal, OrdinalVal: Fifth},

	"nearest":  {Kind: tokenNearest},
	"next":     {Kind: tokenNext},
	"previous": {Kind: tokenPrevious},

	"min":     {Kind: tokenIntervalUnit, UnitVal: IntervalMin},
	"mins":    {Kind: tokenIntervalUnit, UnitVal: IntervalMin},
	"minute":  {Kind: tokenIntervalUnit, UnitVal: IntervalMin},
	"minutes": {Kind: tokenIntervalUnit, UnitVal: IntervalMin},
	"hour":    {Kind: tokenIntervalUnit, UnitVal: IntervalHours},
	"hours":   {Kind: tokenIntervalUnit, UnitVal: IntervalHours},
	"hr":      {Kind: tokenIntervalUnit, UnitVal: IntervalHours},
	"hrs":     {Kind: tokenIntervalUnit, UnitVal: IntervalHours},
}

func isDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

func isAlpha(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func isAlphanumeric(b byte) bool {
	return isAlpha(b) || isDigit(b)
}

// Only these four separate tokens; any other whitespace is an unexpected character.
func isWhitespace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}
