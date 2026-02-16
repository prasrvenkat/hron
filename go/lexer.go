package hron

import (
	"strconv"
	"strings"
)

// TokenKind represents the type of token.
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

// Token represents a lexed token.
type Token struct {
	Kind TokenKind
	Span Span

	// Value fields (only one is set based on Kind)
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

// lexer is the internal lexer state.
type lexer struct {
	input   string
	pos     int
	afterIn bool
}

// Tokenize tokenizes the input string into a list of tokens.
func Tokenize(input string) ([]Token, error) {
	l := &lexer{input: input}
	return l.tokenize()
}

func (l *lexer) tokenize() ([]Token, error) {
	var tokens []Token
	for {
		l.skipWhitespace()
		if l.pos >= len(l.input) {
			break
		}

		if l.afterIn {
			l.afterIn = false
			tok, err := l.lexTimezone()
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, tok)
			continue
		}

		start := l.pos
		ch := l.input[l.pos]

		if ch == ',' {
			l.pos++
			tokens = append(tokens, Token{Kind: TokenComma, Span: Span{start, l.pos}})
			continue
		}

		if isDigit(ch) {
			tok, err := l.lexNumberOrTimeOrDate()
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, tok)
			continue
		}

		if isAlpha(ch) {
			tok, err := l.lexWord()
			if err != nil {
				return nil, err
			}
			tokens = append(tokens, tok)
			continue
		}

		return nil, LexError("unexpected character '"+string(ch)+"'", Span{start, start + 1}, l.input)
	}

	return tokens, nil
}

func (l *lexer) skipWhitespace() {
	for l.pos < len(l.input) && isWhitespace(l.input[l.pos]) {
		l.pos++
	}
}

func (l *lexer) lexTimezone() (Token, error) {
	l.skipWhitespace()
	start := l.pos
	for l.pos < len(l.input) && !isWhitespace(l.input[l.pos]) {
		l.pos++
	}
	tz := l.input[start:l.pos]
	if len(tz) == 0 {
		return Token{}, LexError("expected timezone after 'in'", Span{start, start + 1}, l.input)
	}
	return Token{Kind: TokenTimezone, Span: Span{start, l.pos}, TimezoneVal: tz}, nil
}

func (l *lexer) lexNumberOrTimeOrDate() (Token, error) {
	start := l.pos

	// Read digits
	numStart := l.pos
	for l.pos < len(l.input) && isDigit(l.input[l.pos]) {
		l.pos++
	}
	digits := l.input[numStart:l.pos]

	// Check for ISO date: YYYY-MM-DD
	if len(digits) == 4 && l.pos < len(l.input) && l.input[l.pos] == '-' {
		remaining := l.input[start:]
		if len(remaining) >= 10 &&
			remaining[4] == '-' &&
			isDigit(remaining[5]) &&
			isDigit(remaining[6]) &&
			remaining[7] == '-' &&
			isDigit(remaining[8]) &&
			isDigit(remaining[9]) {
			l.pos = start + 10
			return Token{Kind: TokenISODate, Span: Span{start, l.pos}, ISODateVal: l.input[start:l.pos]}, nil
		}
	}

	// Check for time: HH:MM
	if (len(digits) == 1 || len(digits) == 2) && l.pos < len(l.input) && l.input[l.pos] == ':' {
		l.pos++ // skip ':'
		minStart := l.pos
		for l.pos < len(l.input) && isDigit(l.input[l.pos]) {
			l.pos++
		}
		minDigits := l.input[minStart:l.pos]
		if len(minDigits) == 2 {
			hour, err := strconv.Atoi(digits)
			if err != nil {
				return Token{}, LexError("invalid time hour", Span{start, l.pos}, l.input)
			}
			minute, err := strconv.Atoi(minDigits)
			if err != nil {
				return Token{}, LexError("invalid time minute", Span{start, l.pos}, l.input)
			}
			if hour > 23 || minute > 59 {
				return Token{}, LexError("invalid time", Span{start, l.pos}, l.input)
			}
			return Token{Kind: TokenTime, Span: Span{start, l.pos}, TimeHour: hour, TimeMinute: minute}, nil
		}
	}

	num, err := strconv.Atoi(digits)
	if err != nil {
		return Token{}, LexError("invalid number", Span{start, l.pos}, l.input)
	}

	// Check for ordinal suffix: st, nd, rd, th
	if l.pos+1 < len(l.input) {
		suffix := strings.ToLower(l.input[l.pos : l.pos+2])
		if suffix == "st" || suffix == "nd" || suffix == "rd" || suffix == "th" {
			l.pos += 2
			return Token{Kind: TokenOrdinalNumber, Span: Span{start, l.pos}, NumberVal: num}, nil
		}
	}

	return Token{Kind: TokenNumber, Span: Span{start, l.pos}, NumberVal: num}, nil
}

func (l *lexer) lexWord() (Token, error) {
	start := l.pos
	for l.pos < len(l.input) && (isAlphanumeric(l.input[l.pos]) || l.input[l.pos] == '_') {
		l.pos++
	}
	word := strings.ToLower(l.input[start:l.pos])
	span := Span{start, l.pos}

	// Check keyword map
	tok, ok := keywordMap[word]
	if !ok {
		return Token{}, LexError("unknown keyword '"+word+"'", span, l.input)
	}

	tok.Span = span

	if tok.Kind == TokenIn {
		l.afterIn = true
	}

	return tok, nil
}

// keywordMap maps lowercase keywords to tokens.
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
	// Day names
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
	// Month names
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
	// Ordinals
	"first":  {Kind: TokenOrdinal, OrdinalVal: First},
	"second": {Kind: TokenOrdinal, OrdinalVal: Second},
	"third":  {Kind: TokenOrdinal, OrdinalVal: Third},
	"fourth": {Kind: TokenOrdinal, OrdinalVal: Fourth},
	"fifth":  {Kind: TokenOrdinal, OrdinalVal: Fifth},
	// Nearest weekday keywords
	"nearest":  {Kind: TokenNearest},
	"next":     {Kind: TokenNext},
	"previous": {Kind: TokenPrevious},
	// Interval units
	"min":     {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"mins":    {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"minute":  {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"minutes": {Kind: TokenIntervalUnit, UnitVal: IntervalMin},
	"hour":    {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hours":   {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hr":      {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
	"hrs":     {Kind: TokenIntervalUnit, UnitVal: IntervalHours},
}

// Helper functions

func isDigit(b byte) bool {
	return b >= '0' && b <= '9'
}

func isAlpha(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func isAlphanumeric(b byte) bool {
	return isAlpha(b) || isDigit(b)
}

func isWhitespace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

