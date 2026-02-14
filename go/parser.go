package hron

import "fmt"

// parser is the internal parser state.
type parser struct {
	tokens []Token
	pos    int
	input  string
}

// Parse parses an hron expression string into a ScheduleData.
func Parse(input string) (*ScheduleData, error) {
	tokens, err := Tokenize(input)
	if err != nil {
		return nil, err
	}

	if len(tokens) == 0 {
		return nil, ParseError("empty expression", Span{0, 0}, input, "")
	}

	p := &parser{tokens: tokens, input: input}
	schedule, err := p.parseExpression()
	if err != nil {
		return nil, err
	}

	if p.peek() != nil {
		return nil, ParseError("unexpected tokens after expression", p.currentSpan(), input, "")
	}

	return schedule, nil
}

func (p *parser) peek() *Token {
	if p.pos < len(p.tokens) {
		return &p.tokens[p.pos]
	}
	return nil
}

func (p *parser) peekKind() TokenKind {
	tok := p.peek()
	if tok != nil {
		return tok.Kind
	}
	return -1
}

func (p *parser) advance() *Token {
	tok := p.peek()
	if tok != nil {
		p.pos++
	}
	return tok
}

func (p *parser) currentSpan() Span {
	tok := p.peek()
	if tok != nil {
		return tok.Span
	}
	if len(p.tokens) > 0 {
		last := p.tokens[len(p.tokens)-1]
		return Span{last.Span.End, last.Span.End}
	}
	return Span{0, 0}
}

func (p *parser) error(message string, span Span) error {
	return ParseError(message, span, p.input, "")
}

func (p *parser) errorAtEnd(message string) error {
	span := Span{0, 0}
	if len(p.tokens) > 0 {
		end := p.tokens[len(p.tokens)-1].Span.End
		span = Span{end, end}
	}
	return ParseError(message, span, p.input, "")
}

func (p *parser) consume(expected string, kind TokenKind) (*Token, error) {
	span := p.currentSpan()
	tok := p.peek()
	if tok != nil && tok.Kind == kind {
		p.pos++
		return tok, nil
	}
	if tok != nil {
		return nil, p.error(fmt.Sprintf("expected %s", expected), span)
	}
	return nil, p.errorAtEnd(fmt.Sprintf("expected %s", expected))
}

// --- Grammar productions ---

func (p *parser) parseExpression() (*ScheduleData, error) {
	span := p.currentSpan()
	kind := p.peekKind()

	var expr ScheduleExpr
	var err error

	switch kind {
	case TokenEvery:
		p.advance()
		expr, err = p.parseEvery()
	case TokenOn:
		p.advance()
		expr, err = p.parseOn()
	case TokenOrdinal, TokenLast:
		expr, err = p.parseOrdinalRepeat()
	default:
		return nil, p.error("expected 'every', 'on', or an ordinal (first, second, ...)", span)
	}

	if err != nil {
		return nil, err
	}

	return p.parseTrailingClauses(expr)
}

func (p *parser) parseTrailingClauses(expr ScheduleExpr) (*ScheduleData, error) {
	schedule := NewScheduleData(expr)

	// except
	if p.peekKind() == TokenExcept {
		p.advance()
		exceptions, err := p.parseExceptionList()
		if err != nil {
			return nil, err
		}
		schedule.Except = exceptions
	}

	// until
	if p.peekKind() == TokenUntil {
		p.advance()
		until, err := p.parseUntilSpec()
		if err != nil {
			return nil, err
		}
		schedule.Until = &until
	}

	// starting
	if p.peekKind() == TokenStarting {
		p.advance()
		if p.peekKind() == TokenISODate {
			schedule.Anchor = p.peek().ISODateVal
			p.advance()
		} else {
			return nil, p.error("expected ISO date (YYYY-MM-DD) after 'starting'", p.currentSpan())
		}
	}

	// during
	if p.peekKind() == TokenDuring {
		p.advance()
		months, err := p.parseMonthList()
		if err != nil {
			return nil, err
		}
		schedule.During = months
	}

	// in <timezone>
	if p.peekKind() == TokenIn {
		p.advance()
		if p.peekKind() == TokenTimezone {
			schedule.Timezone = p.peek().TimezoneVal
			p.advance()
		} else {
			return nil, p.error("expected timezone after 'in'", p.currentSpan())
		}
	}

	return schedule, nil
}

func (p *parser) parseExceptionList() ([]ExceptionSpec, error) {
	exc, err := p.parseException()
	if err != nil {
		return nil, err
	}
	exceptions := []ExceptionSpec{exc}

	for p.peekKind() == TokenComma {
		p.advance()
		exc, err := p.parseException()
		if err != nil {
			return nil, err
		}
		exceptions = append(exceptions, exc)
	}

	return exceptions, nil
}

func (p *parser) parseException() (ExceptionSpec, error) {
	tok := p.peek()
	if tok == nil {
		return ExceptionSpec{}, p.errorAtEnd("expected exception date")
	}

	switch tok.Kind {
	case TokenISODate:
		p.advance()
		return NewISOException(tok.ISODateVal), nil
	case TokenMonthName:
		month := tok.MonthNameVal
		p.advance()
		day, err := p.parseDayNumber("expected day number after month name in exception")
		if err != nil {
			return ExceptionSpec{}, err
		}
		return NewNamedException(month, day), nil
	default:
		return ExceptionSpec{}, p.error("expected ISO date or month-day in exception", p.currentSpan())
	}
}

func (p *parser) parseUntilSpec() (UntilSpec, error) {
	tok := p.peek()
	if tok == nil {
		return UntilSpec{}, p.errorAtEnd("expected until date")
	}

	switch tok.Kind {
	case TokenISODate:
		p.advance()
		return NewISOUntil(tok.ISODateVal), nil
	case TokenMonthName:
		month := tok.MonthNameVal
		p.advance()
		day, err := p.parseDayNumber("expected day number after month name in until")
		if err != nil {
			return UntilSpec{}, err
		}
		return NewNamedUntil(month, day), nil
	default:
		return UntilSpec{}, p.error("expected ISO date or month-day after 'until'", p.currentSpan())
	}
}

func (p *parser) parseDayNumber(errorMsg string) (int, error) {
	tok := p.peek()
	if tok == nil {
		return 0, p.errorAtEnd(errorMsg)
	}

	switch tok.Kind {
	case TokenNumber:
		p.advance()
		return tok.NumberVal, nil
	case TokenOrdinalNumber:
		p.advance()
		return tok.NumberVal, nil
	default:
		return 0, p.error(errorMsg, p.currentSpan())
	}
}

// After "every": dispatch
func (p *parser) parseEvery() (ScheduleExpr, error) {
	if p.peek() == nil {
		return ScheduleExpr{}, p.errorAtEnd("expected repeater")
	}

	switch p.peekKind() {
	case TokenYear:
		p.advance()
		return p.parseYearRepeat(1)
	case TokenDay:
		return p.parseDayRepeat(1, NewDayFilterEvery())
	case TokenWeekday:
		p.advance()
		return p.parseDayRepeat(1, NewDayFilterWeekday())
	case TokenWeekend:
		p.advance()
		return p.parseDayRepeat(1, NewDayFilterWeekend())
	case TokenDayName:
		days, err := p.parseDayList()
		if err != nil {
			return ScheduleExpr{}, err
		}
		return p.parseDayRepeat(1, NewDayFilterDays(days))
	case TokenMonth:
		p.advance()
		return p.parseMonthRepeat(1)
	case TokenNumber:
		return p.parseNumberRepeat()
	default:
		return ScheduleExpr{}, p.error(
			"expected day, weekday, weekend, year, day name, month, or number after 'every'",
			p.currentSpan(),
		)
	}
}

func (p *parser) parseDayRepeat(interval int, days DayFilter) (ScheduleExpr, error) {
	if days.Kind == DayFilterKindEvery {
		if _, err := p.consume("'day'", TokenDay); err != nil {
			return ScheduleExpr{}, err
		}
	}
	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewDayRepeat(interval, days, times), nil
}

func (p *parser) parseNumberRepeat() (ScheduleExpr, error) {
	span := p.currentSpan()
	tok := p.peek()
	num := tok.NumberVal
	if num == 0 {
		return ScheduleExpr{}, p.error("interval must be at least 1", span)
	}
	p.advance()

	switch p.peekKind() {
	case TokenWeeks:
		p.advance()
		return p.parseWeekRepeat(num)
	case TokenIntervalUnit:
		return p.parseIntervalRepeat(num)
	case TokenDay:
		return p.parseDayRepeat(num, NewDayFilterEvery())
	case TokenMonth:
		p.advance()
		return p.parseMonthRepeat(num)
	case TokenYear:
		p.advance()
		return p.parseYearRepeat(num)
	default:
		return ScheduleExpr{}, p.error(
			"expected 'weeks', 'min', 'minutes', 'hour', 'hours', 'day(s)', 'month(s)', or 'year(s)' after number",
			p.currentSpan(),
		)
	}
}

func (p *parser) parseIntervalRepeat(interval int) (ScheduleExpr, error) {
	tok := p.peek()
	unit := tok.UnitVal
	p.advance()

	if _, err := p.consume("'from'", TokenFrom); err != nil {
		return ScheduleExpr{}, err
	}
	fromTime, err := p.parseTime()
	if err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'to'", TokenTo); err != nil {
		return ScheduleExpr{}, err
	}
	toTime, err := p.parseTime()
	if err != nil {
		return ScheduleExpr{}, err
	}

	var dayFilter *DayFilter
	if p.peekKind() == TokenOn {
		p.advance()
		df, err := p.parseDayTarget()
		if err != nil {
			return ScheduleExpr{}, err
		}
		dayFilter = &df
	}

	return NewIntervalRepeat(interval, unit, fromTime, toTime, dayFilter), nil
}

func (p *parser) parseWeekRepeat(interval int) (ScheduleExpr, error) {
	if _, err := p.consume("'on'", TokenOn); err != nil {
		return ScheduleExpr{}, err
	}
	days, err := p.parseDayList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewWeekRepeat(interval, days, times), nil
}

func (p *parser) parseMonthRepeat(interval int) (ScheduleExpr, error) {
	if _, err := p.consume("'on'", TokenOn); err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'the'", TokenThe); err != nil {
		return ScheduleExpr{}, err
	}

	var target MonthTarget

	switch p.peekKind() {
	case TokenLast:
		p.advance()
		switch p.peekKind() {
		case TokenDay:
			p.advance()
			target = NewLastDayTarget()
		case TokenWeekday:
			p.advance()
			target = NewLastWeekdayTarget()
		default:
			return ScheduleExpr{}, p.error("expected 'day' or 'weekday' after 'last'", p.currentSpan())
		}
	case TokenOrdinalNumber:
		specs, err := p.parseOrdinalDayList()
		if err != nil {
			return ScheduleExpr{}, err
		}
		target = NewDaysTarget(specs)
	case TokenNext, TokenPrevious, TokenNearest:
		var err error
		target, err = p.parseNearestWeekdayTarget()
		if err != nil {
			return ScheduleExpr{}, err
		}
	default:
		return ScheduleExpr{}, p.error(
			"expected ordinal day (1st, 15th), 'last', or '[next|previous] nearest' after 'the'",
			p.currentSpan(),
		)
	}

	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewMonthRepeat(interval, target, times), nil
}

func (p *parser) parseNearestWeekdayTarget() (MonthTarget, error) {
	// Optional direction: "next" or "previous"
	direction := NearestNone
	switch p.peekKind() {
	case TokenNext:
		p.advance()
		direction = NearestNext
	case TokenPrevious:
		p.advance()
		direction = NearestPrevious
	}

	if _, err := p.consume("'nearest'", TokenNearest); err != nil {
		return MonthTarget{}, err
	}
	if _, err := p.consume("'weekday'", TokenWeekday); err != nil {
		return MonthTarget{}, err
	}
	if _, err := p.consume("'to'", TokenTo); err != nil {
		return MonthTarget{}, err
	}

	if p.peekKind() != TokenOrdinalNumber {
		return MonthTarget{}, p.error("expected ordinal day number", p.currentSpan())
	}
	tok := p.peek()
	day := tok.NumberVal
	p.advance()

	return NewNearestWeekdayTarget(day, direction), nil
}

func (p *parser) parseOrdinalRepeat() (ScheduleExpr, error) {
	ordinal, err := p.parseOrdinalPosition()
	if err != nil {
		return ScheduleExpr{}, err
	}

	tok := p.peek()
	if tok == nil || tok.Kind != TokenDayName {
		return ScheduleExpr{}, p.error("expected day name after ordinal", p.currentSpan())
	}
	day := tok.DayNameVal
	p.advance()

	if _, err := p.consume("'of'", TokenOf); err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'every'", TokenEvery); err != nil {
		return ScheduleExpr{}, err
	}

	// "of every [N] month(s) at ..."
	interval := 1
	if p.peekKind() == TokenNumber {
		tok := p.peek()
		interval = tok.NumberVal
		if interval == 0 {
			return ScheduleExpr{}, p.error("interval must be at least 1", p.currentSpan())
		}
		p.advance()
	}

	if _, err := p.consume("'month'", TokenMonth); err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}

	return NewOrdinalRepeat(interval, ordinal, day, times), nil
}

func (p *parser) parseYearRepeat(interval int) (ScheduleExpr, error) {
	if _, err := p.consume("'on'", TokenOn); err != nil {
		return ScheduleExpr{}, err
	}

	var target YearTarget

	switch p.peekKind() {
	case TokenThe:
		p.advance()
		var err error
		target, err = p.parseYearTargetAfterThe()
		if err != nil {
			return ScheduleExpr{}, err
		}
	case TokenMonthName:
		tok := p.peek()
		month := tok.MonthNameVal
		p.advance()
		day, err := p.parseDayNumber("expected day number after month name")
		if err != nil {
			return ScheduleExpr{}, err
		}
		target = NewYearDateTarget(month, day)
	default:
		return ScheduleExpr{}, p.error(
			"expected month name or 'the' after 'every year on'",
			p.currentSpan(),
		)
	}

	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewYearRepeat(interval, target, times), nil
}

func (p *parser) parseYearTargetAfterThe() (YearTarget, error) {
	switch p.peekKind() {
	case TokenLast:
		p.advance()
		switch p.peekKind() {
		case TokenWeekday:
			p.advance()
			if _, err := p.consume("'of'", TokenOf); err != nil {
				return YearTarget{}, err
			}
			month, err := p.parseMonthNameToken()
			if err != nil {
				return YearTarget{}, err
			}
			return NewYearLastWeekdayTarget(month), nil
		case TokenDayName:
			tok := p.peek()
			weekday := tok.DayNameVal
			p.advance()
			if _, err := p.consume("'of'", TokenOf); err != nil {
				return YearTarget{}, err
			}
			month, err := p.parseMonthNameToken()
			if err != nil {
				return YearTarget{}, err
			}
			return NewYearOrdinalWeekdayTarget(Last, weekday, month), nil
		default:
			return YearTarget{}, p.error(
				"expected 'weekday' or day name after 'last' in yearly expression",
				p.currentSpan(),
			)
		}

	case TokenOrdinal:
		ordinal, err := p.parseOrdinalPosition()
		if err != nil {
			return YearTarget{}, err
		}
		if p.peekKind() == TokenDayName {
			tok := p.peek()
			weekday := tok.DayNameVal
			p.advance()
			if _, err := p.consume("'of'", TokenOf); err != nil {
				return YearTarget{}, err
			}
			month, err := p.parseMonthNameToken()
			if err != nil {
				return YearTarget{}, err
			}
			return NewYearOrdinalWeekdayTarget(ordinal, weekday, month), nil
		}
		return YearTarget{}, p.error(
			"expected day name after ordinal in yearly expression",
			p.currentSpan(),
		)

	case TokenOrdinalNumber:
		tok := p.peek()
		day := tok.NumberVal
		p.advance()
		if _, err := p.consume("'of'", TokenOf); err != nil {
			return YearTarget{}, err
		}
		month, err := p.parseMonthNameToken()
		if err != nil {
			return YearTarget{}, err
		}
		return NewYearDayOfMonthTarget(day, month), nil

	default:
		return YearTarget{}, p.error(
			"expected ordinal, day number, or 'last' after 'the' in yearly expression",
			p.currentSpan(),
		)
	}
}

func (p *parser) parseMonthNameToken() (MonthName, error) {
	if p.peekKind() != TokenMonthName {
		return 0, p.error("expected month name", p.currentSpan())
	}
	tok := p.peek()
	p.advance()
	return tok.MonthNameVal, nil
}

func (p *parser) parseOrdinalPosition() (OrdinalPosition, error) {
	span := p.currentSpan()
	switch p.peekKind() {
	case TokenOrdinal:
		tok := p.peek()
		p.advance()
		return tok.OrdinalVal, nil
	case TokenLast:
		p.advance()
		return Last, nil
	default:
		return 0, p.error("expected ordinal (first, second, third, fourth, fifth, last)", span)
	}
}

func (p *parser) parseOn() (ScheduleExpr, error) {
	date, err := p.parseDateTarget()
	if err != nil {
		return ScheduleExpr{}, err
	}
	if _, err := p.consume("'at'", TokenAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewSingleDateExpr(date, times), nil
}

func (p *parser) parseDateTarget() (DateSpec, error) {
	tok := p.peek()
	if tok == nil {
		return DateSpec{}, p.errorAtEnd("expected date")
	}

	switch tok.Kind {
	case TokenISODate:
		p.advance()
		return NewISODate(tok.ISODateVal), nil
	case TokenMonthName:
		month := tok.MonthNameVal
		p.advance()
		day, err := p.parseDayNumber("expected day number after month name")
		if err != nil {
			return DateSpec{}, err
		}
		return NewNamedDate(month, day), nil
	default:
		return DateSpec{}, p.error("expected date (ISO date or month name)", p.currentSpan())
	}
}

func (p *parser) parseDayTarget() (DayFilter, error) {
	switch p.peekKind() {
	case TokenDay:
		p.advance()
		return NewDayFilterEvery(), nil
	case TokenWeekday:
		p.advance()
		return NewDayFilterWeekday(), nil
	case TokenWeekend:
		p.advance()
		return NewDayFilterWeekend(), nil
	case TokenDayName:
		days, err := p.parseDayList()
		if err != nil {
			return DayFilter{}, err
		}
		return NewDayFilterDays(days), nil
	default:
		return DayFilter{}, p.error("expected 'day', 'weekday', 'weekend', or day name", p.currentSpan())
	}
}

func (p *parser) parseDayList() ([]Weekday, error) {
	if p.peekKind() != TokenDayName {
		return nil, p.error("expected day name", p.currentSpan())
	}
	tok := p.peek()
	days := []Weekday{tok.DayNameVal}
	p.advance()

	for p.peekKind() == TokenComma {
		p.advance()
		if p.peekKind() != TokenDayName {
			return nil, p.error("expected day name after ','", p.currentSpan())
		}
		tok := p.peek()
		days = append(days, tok.DayNameVal)
		p.advance()
	}

	return days, nil
}

func (p *parser) parseOrdinalDayList() ([]DayOfMonthSpec, error) {
	spec, err := p.parseOrdinalDaySpec()
	if err != nil {
		return nil, err
	}
	specs := []DayOfMonthSpec{spec}

	for p.peekKind() == TokenComma {
		p.advance()
		spec, err := p.parseOrdinalDaySpec()
		if err != nil {
			return nil, err
		}
		specs = append(specs, spec)
	}

	return specs, nil
}

func (p *parser) parseOrdinalDaySpec() (DayOfMonthSpec, error) {
	if p.peekKind() != TokenOrdinalNumber {
		return DayOfMonthSpec{}, p.error("expected ordinal day number", p.currentSpan())
	}
	tok := p.peek()
	start := tok.NumberVal
	p.advance()

	if p.peekKind() == TokenTo {
		p.advance()
		if p.peekKind() != TokenOrdinalNumber {
			return DayOfMonthSpec{}, p.error("expected ordinal day number after 'to'", p.currentSpan())
		}
		tok := p.peek()
		end := tok.NumberVal
		p.advance()
		return NewDayRange(start, end), nil
	}

	return NewSingleDay(start), nil
}

func (p *parser) parseMonthList() ([]MonthName, error) {
	month, err := p.parseMonthNameToken()
	if err != nil {
		return nil, err
	}
	months := []MonthName{month}

	for p.peekKind() == TokenComma {
		p.advance()
		month, err := p.parseMonthNameToken()
		if err != nil {
			return nil, err
		}
		months = append(months, month)
	}

	return months, nil
}

func (p *parser) parseTimeList() ([]TimeOfDay, error) {
	t, err := p.parseTime()
	if err != nil {
		return nil, err
	}
	times := []TimeOfDay{t}

	for p.peekKind() == TokenComma {
		p.advance()
		t, err := p.parseTime()
		if err != nil {
			return nil, err
		}
		times = append(times, t)
	}

	return times, nil
}

func (p *parser) parseTime() (TimeOfDay, error) {
	span := p.currentSpan()
	if p.peekKind() != TokenTime {
		return TimeOfDay{}, p.error("expected time (HH:MM)", span)
	}
	tok := p.peek()
	p.advance()
	return TimeOfDay{Hour: tok.TimeHour, Minute: tok.TimeMinute}, nil
}
