package hron

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

type TokenKind int

const (
	TokenEvery TokenKind = iota
	TokenOn
	TokenAt
	TokenFrom
	TokenTo
	TokenIn
	TokenOf
	TokenThe
	TokenLast
	TokenExcept
	TokenUntil
	TokenStarting
	TokenDuring
	TokenYear
	TokenDay
	TokenWeekday
	TokenWeekend
	TokenWeeks
	TokenMonth
	TokenDayName
	TokenMonthName
	TokenOrdinal
	TokenIntervalUnit
	TokenNumber
	TokenOrdinalNumber
	TokenTime
	TokenISODate
	TokenComma
	TokenTimezone
	TokenNearest
	TokenNext
	TokenPrevious
)

type Token struct {
	Kind TokenKind
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

// Tokenize splits input into tokens, or returns a lex *HronError. Token spans
// are byte offsets into input.
func Tokenize(input string) ([]Token, error) {
	l := &lexer{input: input}
	return l.tokenize()
}

func (l *lexer) tokenize() ([]Token, error) {
	var tokens []Token
	for {
		l.advanceWhile(isWhitespace)
		if l.pos >= len(l.input) {
			return tokens, nil
		}
		start := l.pos
		c := l.input[l.pos]
		var tok Token
		var err error
		switch {
		case len(tokens) > 0 && tokens[len(tokens)-1].Kind == TokenIn:
			l.advanceWhile(func(b byte) bool { return !isWhitespace(b) })
			tok = Token{Kind: TokenTimezone, TimezoneVal: l.input[start:l.pos]}
		case c == ',':
			l.pos++
			tok = Token{Kind: TokenComma}
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

func (l *lexer) word(start int) (Token, error) {
	l.advanceWhile(func(b byte) bool { return isAlphanumeric(b) || b == '_' })
	text := l.input[start:l.pos]
	tok, ok := keywordMap[asciiLower(text)]
	if !ok {
		return Token{}, l.error("unknown keyword '"+text+"'", start)
	}
	return tok, nil
}

func (l *lexer) digits(start int) (Token, error) {
	l.advanceWhile(isDigit)
	digits := l.input[start:l.pos]
	rest := l.input[l.pos:]
	if len(digits) == 4 && isISODateTail(rest) {
		l.pos += len("-MM-DD")
		return Token{Kind: TokenISODate, ISODateVal: l.input[start:l.pos]}, nil
	}
	if strings.HasPrefix(rest, ":") {
		return l.time(start)
	}
	value, ok := numberValue(digits)
	if !ok {
		return Token{}, l.error("number must be at most 2147483647", start)
	}
	if isOrdinalSuffix(rest) {
		l.pos += 2
		return Token{Kind: TokenOrdinalNumber, NumberVal: value}, nil
	}
	return Token{Kind: TokenNumber, NumberVal: value}, nil
}

func (l *lexer) time(start int) (Token, error) {
	colon := l.pos
	l.pos++
	l.advanceWhile(isDigit)
	hour, minute, text := l.input[start:colon], l.input[colon+1:l.pos], l.input[start:l.pos]
	if len(hour) > 2 || len(minute) != 2 {
		return Token{}, l.error("time must be H:MM or HH:MM, got "+text, start)
	}
	h, m := twoDigitValue(hour), twoDigitValue(minute)
	if h > 23 || m > 59 {
		return Token{}, l.error("time must be 00:00-23:59, got "+text, start)
	}
	return Token{Kind: TokenTime, TimeHour: h, TimeMinute: m}, nil
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

var keywordMap = map[string]Token{
	"every":    {Kind: TokenEvery},
	"on":       {Kind: TokenOn},
	"at":       {Kind: TokenAt},
	"from":     {Kind: TokenFrom},
	"to":       {Kind: TokenTo},
	"in":       {Kind: TokenIn},
	"of":       {Kind: TokenOf},
	"the":      {Kind: TokenThe},
	"last":     {Kind: TokenLast},
	"except":   {Kind: TokenExcept},
	"until":    {Kind: TokenUntil},
	"starting": {Kind: TokenStarting},
	"during":   {Kind: TokenDuring},
	"year":     {Kind: TokenYear},
	"years":    {Kind: TokenYear},
	"day":      {Kind: TokenDay},
	"days":     {Kind: TokenDay},
	"weekday":  {Kind: TokenWeekday},
	"weekdays": {Kind: TokenWeekday},
	"weekend":  {Kind: TokenWeekend},
	"weekends": {Kind: TokenWeekend},
	"weeks":    {Kind: TokenWeeks},
	"week":     {Kind: TokenWeeks},
	"month":    {Kind: TokenMonth},
	"months":   {Kind: TokenMonth},

	"monday":    {Kind: TokenDayName, DayNameVal: Monday},
	"mon":       {Kind: TokenDayName, DayNameVal: Monday},
	"tuesday":   {Kind: TokenDayName, DayNameVal: Tuesday},
	"tue":       {Kind: TokenDayName, DayNameVal: Tuesday},
	"wednesday": {Kind: TokenDayName, DayNameVal: Wednesday},
	"wed":       {Kind: TokenDayName, DayNameVal: Wednesday},
	"thursday":  {Kind: TokenDayName, DayNameVal: Thursday},
	"thu":       {Kind: TokenDayName, DayNameVal: Thursday},
	"friday":    {Kind: TokenDayName, DayNameVal: Friday},
	"fri":       {Kind: TokenDayName, DayNameVal: Friday},
	"saturday":  {Kind: TokenDayName, DayNameVal: Saturday},
	"sat":       {Kind: TokenDayName, DayNameVal: Saturday},
	"sunday":    {Kind: TokenDayName, DayNameVal: Sunday},
	"sun":       {Kind: TokenDayName, DayNameVal: Sunday},

	"january":   {Kind: TokenMonthName, MonthNameVal: Jan},
	"jan":       {Kind: TokenMonthName, MonthNameVal: Jan},
	"february":  {Kind: TokenMonthName, MonthNameVal: Feb},
	"feb":       {Kind: TokenMonthName, MonthNameVal: Feb},
	"march":     {Kind: TokenMonthName, MonthNameVal: Mar},
	"mar":       {Kind: TokenMonthName, MonthNameVal: Mar},
	"april":     {Kind: TokenMonthName, MonthNameVal: Apr},
	"apr":       {Kind: TokenMonthName, MonthNameVal: Apr},
	"may":       {Kind: TokenMonthName, MonthNameVal: May},
	"june":      {Kind: TokenMonthName, MonthNameVal: Jun},
	"jun":       {Kind: TokenMonthName, MonthNameVal: Jun},
	"july":      {Kind: TokenMonthName, MonthNameVal: Jul},
	"jul":       {Kind: TokenMonthName, MonthNameVal: Jul},
	"august":    {Kind: TokenMonthName, MonthNameVal: Aug},
	"aug":       {Kind: TokenMonthName, MonthNameVal: Aug},
	"september": {Kind: TokenMonthName, MonthNameVal: Sep},
	"sep":       {Kind: TokenMonthName, MonthNameVal: Sep},
	"october":   {Kind: TokenMonthName, MonthNameVal: Oct},
	"oct":       {Kind: TokenMonthName, MonthNameVal: Oct},
	"november":  {Kind: TokenMonthName, MonthNameVal: Nov},
	"nov":       {Kind: TokenMonthName, MonthNameVal: Nov},
	"december":  {Kind: TokenMonthName, MonthNameVal: Dec},
	"dec":       {Kind: TokenMonthName, MonthNameVal: Dec},

	"first":  {Kind: TokenOrdinal, OrdinalVal: First},
	"second": {Kind: TokenOrdinal, OrdinalVal: Second},
	"third":  {Kind: TokenOrdinal, OrdinalVal: Third},
	"fourth": {Kind: TokenOrdinal, OrdinalVal: Fourth},
	"fifth":  {Kind: TokenOrdinal, OrdinalVal: Fifth},

	"nearest":  {Kind: TokenNearest},
	"next":     {Kind: TokenNext},
	"previous": {Kind: TokenPrevious},

	"min":     {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"mins":    {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"minute":  {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"minutes": {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"hour":    {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hours":   {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hr":      {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hrs":     {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
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
