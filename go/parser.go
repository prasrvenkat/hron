package hron

import "fmt"

// The {what} of each "expected {what}, got ..." error, one per phrase in the
// position table of spec/README.md, "Parse errors".
const (
	expectedEveryOrOn  = "'every' or 'on'"
	expectedRepeater   = "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number"
	expectedUnit       = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')"
	expectedAt         = "'at'"
	expectedTime       = "a time (HH:MM)"
	expectedFrom       = "'from'"
	expectedTo         = "'to'"
	expectedDayTarget  = "'day', 'weekday', 'weekend' or a day name"
	expectedOn         = "'on'"
	expectedDayName    = "a day name"
	expectedThe        = "'the'"
	expectedMonthTgt   = "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'"
	expectedMonthLast  = "'day', 'weekday' or a day name"
	expectedNearest    = "'nearest'"
	expectedWeekday    = "'weekday'"
	expectedDayOfMonth = "a day such as 15th"
	expectedYearTarget = "a month name or 'the'"
	expectedYearThe    = "a day such as 15th, 'last' or an ordinal such as 'first'"
	expectedYearLast   = "'weekday' or a day name"
	expectedOf         = "'of'"
	expectedMonthName  = "a month name"
	expectedDayNumber  = "a day number"
	expectedDate       = "a date (YYYY-MM-DD, or a month and day)"
	expectedISODate    = "a date (YYYY-MM-DD)"
	expectedTimezone   = "a timezone"
)

var clauseOrder = []struct {
	kind    TokenKind
	keyword string
}{
	{TokenExcept, "except"},
	{TokenUntil, "until"},
	{TokenStarting, "starting"},
	{TokenDuring, "during"},
	{TokenIn, "in"},
}

type parser struct {
	tokens     []Token
	pos        int
	input      string
	untilBytes Span
}

func parse(input string) (*ScheduleData, error) {
	tokens, err := tokenize(input)
	if err != nil {
		return nil, err
	}
	if len(tokens) == 0 {
		return nil, ParseError("empty expression", Span{0, 0}, input, "")
	}

	p := &parser{tokens: tokens, input: input}
	expr, err := p.parseExpression()
	if err != nil {
		return nil, err
	}
	schedule, err := p.parseClauses(expr)
	if err != nil {
		return nil, err
	}
	if p.peek() != nil {
		return nil, p.leftover(schedule)
	}
	// spec/README.md, "Parse errors": every other error wins over a named until without starting.
	if err := p.checkNamedUntil(schedule); err != nil {
		return nil, err
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
	if tok := p.peek(); tok != nil {
		return tok.Kind
	}
	return -1
}

func (p *parser) advance() *Token {
	tok := &p.tokens[p.pos]
	p.pos++
	return tok
}

func (p *parser) previous() *Token {
	return &p.tokens[p.pos-1]
}

func (p *parser) eat(kind TokenKind) bool {
	found := p.peekKind() == kind
	if found {
		p.pos++
	}
	return found
}

func (p *parser) expect(kind TokenKind, what string) error {
	if p.eat(kind) {
		return nil
	}
	return p.expected(what)
}

func (p *parser) text(tok *Token) string {
	return p.input[tok.Span.Start:tok.Span.End]
}

func (p *parser) error(message string, start, end int) error {
	return ParseError(message, codePointSpan(p.input, start, end), p.input, "")
}

func (p *parser) expected(what string) error {
	if tok := p.peek(); tok != nil {
		return p.error(fmt.Sprintf("expected %s, got '%s'", what, p.text(tok)), tok.Span.Start, tok.Span.End)
	}
	end := p.tokens[len(p.tokens)-1].Span.End
	return p.error(fmt.Sprintf("expected %s, got end of input", what), end, end)
}

func (p *parser) parseExpression() (ScheduleExpr, error) {
	switch p.peekKind() {
	case TokenEvery:
		p.advance()
		return p.parseEvery()
	case TokenOn:
		p.advance()
		return p.parseOn()
	default:
		return ScheduleExpr{}, p.expected(expectedEveryOrOn)
	}
}

func (p *parser) parseClauses(expr ScheduleExpr) (*ScheduleData, error) {
	schedule := NewScheduleData(expr)

	if p.eat(TokenExcept) {
		exceptions, err := p.parseExceptionList()
		if err != nil {
			return nil, err
		}
		schedule.Except = exceptions
	}

	if p.peekKind() == TokenUntil {
		until := p.advance()
		date, err := p.parseDate()
		if err != nil {
			return nil, err
		}
		if date.Kind == DateSpecKindISO {
			spec := NewISOUntil(date.Date)
			schedule.Until = &spec
		} else {
			spec := NewNamedUntil(date.Month, date.Day)
			schedule.Until = &spec
		}
		p.untilBytes = Span{until.Span.Start, p.previous().Span.End}
	}

	if p.eat(TokenStarting) {
		if p.peekKind() != TokenISODate {
			return nil, p.expected(expectedISODate)
		}
		tok := p.advance()
		if err := p.checkISODate(tok); err != nil {
			return nil, err
		}
		schedule.Anchor = tok.ISODateVal
	}

	if p.eat(TokenDuring) {
		months, err := p.parseMonthList()
		if err != nil {
			return nil, err
		}
		schedule.During = months
	}

	if p.eat(TokenIn) {
		if p.peekKind() != TokenTimezone {
			return nil, p.expected(expectedTimezone)
		}
		tok := p.advance()
		canonical, ok := canonicalTimezone(tok.TimezoneVal)
		if !ok {
			return nil, p.error(invalidTimezoneMessage(tok.TimezoneVal), tok.Span.Start, tok.Span.End)
		}
		schedule.Timezone = canonical
	}

	return schedule, nil
}

func (p *parser) leftover(schedule *ScheduleData) error {
	tok := p.peek()
	// Every clause holds at least one item, so a clause was read exactly when its field is set.
	read := []bool{
		len(schedule.Except) > 0,
		schedule.Until != nil,
		schedule.Anchor != "",
		len(schedule.During) > 0,
		schedule.Timezone != "",
	}
	lastRead := -1
	for i, wasRead := range read {
		if wasRead {
			lastRead = i
		}
	}
	message := fmt.Sprintf("unexpected '%s' after the schedule", p.text(tok))
	for i, clause := range clauseOrder {
		if clause.kind != tok.Kind {
			continue
		}
		if read[i] {
			message = fmt.Sprintf("duplicate '%s' clause", clause.keyword)
		} else if lastRead >= 0 {
			message = fmt.Sprintf("'%s' must come before '%s'", clause.keyword, clauseOrder[lastRead].keyword)
		}
	}
	return p.error(message, tok.Span.Start, tok.Span.End)
}

func (p *parser) checkNamedUntil(schedule *ScheduleData) error {
	until := schedule.Until
	if until == nil || until.Kind != UntilSpecKindNamed || schedule.Anchor != "" {
		return nil
	}
	return ParseError(
		noYearMessage(*until),
		codePointSpan(p.input, p.untilBytes.Start, p.untilBytes.End),
		p.input,
		fmt.Sprintf("until %s %d starting YYYY-MM-DD", until.Month, until.Day),
	)
}

func noYearMessage(until UntilSpec) string {
	return fmt.Sprintf("until %s %d has no year: add a starting date, or use an ISO date", until.Month, until.Day)
}

func (p *parser) parseExceptionList() ([]ExceptionSpec, error) {
	var exceptions []ExceptionSpec
	for {
		date, err := p.parseDate()
		if err != nil {
			return nil, err
		}
		if date.Kind == DateSpecKindISO {
			exceptions = append(exceptions, NewISOException(date.Date))
		} else {
			exceptions = append(exceptions, NewNamedException(date.Month, date.Day))
		}
		if !p.eat(TokenComma) {
			return exceptions, nil
		}
	}
}

func (p *parser) parseDate() (DateSpec, error) {
	switch p.peekKind() {
	case TokenISODate:
		tok := p.advance()
		if err := p.checkISODate(tok); err != nil {
			return DateSpec{}, err
		}
		return NewISODate(tok.ISODateVal), nil
	case TokenMonthName:
		month := p.advance().MonthNameVal
		day, err := p.parseDayOf(month)
		if err != nil {
			return DateSpec{}, err
		}
		return NewNamedDate(month, day), nil
	default:
		return DateSpec{}, p.expected(expectedDate)
	}
}

func (p *parser) checkISODate(tok *Token) error {
	if !isCalendarDate(tok.ISODateVal) {
		return p.error(invalidDateMessage(tok.ISODateVal), tok.Span.Start, tok.Span.End)
	}
	return nil
}

func invalidDateMessage(date string) string {
	return "date must be a calendar date from 0001-01-01 to 9999-12-31, got " + date
}

func (p *parser) parseEvery() (ScheduleExpr, error) {
	switch p.peekKind() {
	case TokenDay:
		p.advance()
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
	case TokenWeeks:
		p.advance()
		return p.parseWeekRepeat(1)
	case TokenMonth:
		p.advance()
		return p.parseMonthRepeat(1)
	case TokenYear:
		p.advance()
		return p.parseYearRepeat(1)
	case TokenNumber:
		return p.parseNumberRepeat()
	default:
		return ScheduleExpr{}, p.expected(expectedRepeater)
	}
}

func (p *parser) parseDayRepeat(interval int, days DayFilter) (ScheduleExpr, error) {
	if err := p.expect(TokenAt, expectedAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewDayRepeat(interval, days, times), nil
}

func (p *parser) parseNumberRepeat() (ScheduleExpr, error) {
	number := p.advance()
	interval := number.NumberVal
	if interval == 0 {
		return ScheduleExpr{}, p.error("interval must be 1-2147483647, got "+p.text(number), number.Span.Start, number.Span.End)
	}

	switch p.peekKind() {
	case TokenWeeks:
		p.advance()
		return p.parseWeekRepeat(interval)
	case TokenIntervalUnit:
		return p.parseIntervalRepeat(interval, p.advance().UnitVal)
	case TokenDay:
		p.advance()
		return p.parseDayRepeat(interval, NewDayFilterEvery())
	case TokenMonth:
		p.advance()
		return p.parseMonthRepeat(interval)
	case TokenYear:
		p.advance()
		return p.parseYearRepeat(interval)
	default:
		return ScheduleExpr{}, p.expected(expectedUnit)
	}
}

func (p *parser) parseIntervalRepeat(interval int, unit IntervalUnit) (ScheduleExpr, error) {
	if err := p.expect(TokenFrom, expectedFrom); err != nil {
		return ScheduleExpr{}, err
	}
	from, err := p.parseTime()
	if err != nil {
		return ScheduleExpr{}, err
	}
	fromToken := p.previous()
	if err := p.expect(TokenTo, expectedTo); err != nil {
		return ScheduleExpr{}, err
	}
	to, err := p.parseTime()
	if err != nil {
		return ScheduleExpr{}, err
	}
	toToken := p.previous()
	if from.TotalMinutes() > to.TotalMinutes() {
		return ScheduleExpr{}, p.error(
			fmt.Sprintf("time window must not run backwards: %s to %s (a window cannot cross midnight)", p.text(fromToken), p.text(toToken)),
			fromToken.Span.Start, toToken.Span.End,
		)
	}

	var dayFilter *DayFilter
	if p.eat(TokenOn) {
		filter, err := p.parseDayTarget()
		if err != nil {
			return ScheduleExpr{}, err
		}
		dayFilter = &filter
	}

	return NewIntervalRepeat(interval, unit, from, to, dayFilter), nil
}

func (p *parser) parseWeekRepeat(interval int) (ScheduleExpr, error) {
	if err := p.expect(TokenOn, expectedOn); err != nil {
		return ScheduleExpr{}, err
	}
	days, err := p.parseDayList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	if err := p.expect(TokenAt, expectedAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewWeekRepeat(interval, days, times), nil
}

func (p *parser) parseMonthRepeat(interval int) (ScheduleExpr, error) {
	if err := p.expect(TokenOn, expectedOn); err != nil {
		return ScheduleExpr{}, err
	}
	if err := p.expect(TokenThe, expectedThe); err != nil {
		return ScheduleExpr{}, err
	}

	var target MonthTarget
	switch p.peekKind() {
	case TokenLast:
		p.advance()
		switch p.peekKind() {
		case TokenDay:
			target = NewLastDayTarget()
		case TokenWeekday:
			target = NewLastWeekdayTarget()
		case TokenDayName:
			target = NewOrdinalWeekdayTarget(Last, p.peek().DayNameVal)
		default:
			return ScheduleExpr{}, p.expected(expectedMonthLast)
		}
		p.advance()
	case TokenOrdinal:
		ordinal := p.advance().OrdinalVal
		weekday, err := p.parseDayName()
		if err != nil {
			return ScheduleExpr{}, err
		}
		target = NewOrdinalWeekdayTarget(ordinal, weekday)
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
		return ScheduleExpr{}, p.expected(expectedMonthTgt)
	}

	if err := p.expect(TokenAt, expectedAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewMonthRepeat(interval, target, times), nil
}

func (p *parser) parseNearestWeekdayTarget() (MonthTarget, error) {
	direction := NearestNone
	if p.eat(TokenNext) {
		direction = NearestNext
	} else if p.eat(TokenPrevious) {
		direction = NearestPrevious
	}
	if err := p.expect(TokenNearest, expectedNearest); err != nil {
		return MonthTarget{}, err
	}
	if err := p.expect(TokenWeekday, expectedWeekday); err != nil {
		return MonthTarget{}, err
	}
	if err := p.expect(TokenTo, expectedTo); err != nil {
		return MonthTarget{}, err
	}
	day, _, err := p.parseOrdinalDay()
	if err != nil {
		return MonthTarget{}, err
	}
	return NewNearestWeekdayTarget(day, direction), nil
}

func (p *parser) parseOrdinalDayList() ([]DayOfMonthSpec, error) {
	var specs []DayOfMonthSpec
	for {
		spec, err := p.parseOrdinalDaySpec()
		if err != nil {
			return nil, err
		}
		specs = append(specs, spec)
		if !p.eat(TokenComma) {
			return specs, nil
		}
	}
}

func (p *parser) parseOrdinalDaySpec() (DayOfMonthSpec, error) {
	start, startToken, err := p.parseOrdinalDay()
	if err != nil {
		return DayOfMonthSpec{}, err
	}
	if !p.eat(TokenTo) {
		return NewSingleDay(start), nil
	}
	end, endToken, err := p.parseOrdinalDay()
	if err != nil {
		return DayOfMonthSpec{}, err
	}
	if start > end {
		return DayOfMonthSpec{}, p.error(
			fmt.Sprintf("day range must not run backwards: %s to %s", p.text(startToken), p.text(endToken)),
			startToken.Span.Start, endToken.Span.End,
		)
	}
	return NewDayRange(start, end), nil
}

func (p *parser) parseOrdinalDay() (int, *Token, error) {
	if p.peekKind() != TokenOrdinalNumber {
		return 0, nil, p.expected(expectedDayOfMonth)
	}
	tok := p.advance()
	if err := p.checkDayOfMonth(tok); err != nil {
		return 0, nil, err
	}
	return tok.NumberVal, tok, nil
}

func (p *parser) parseDayOf(month MonthName) (int, error) {
	if kind := p.peekKind(); kind != TokenNumber && kind != TokenOrdinalNumber {
		return 0, p.expected(expectedDayNumber)
	}
	tok := p.advance()
	if err := p.checkDayOfMonth(tok); err != nil {
		return 0, err
	}
	if err := p.checkDayInMonth(tok, month); err != nil {
		return 0, err
	}
	return tok.NumberVal, nil
}

func (p *parser) checkDayOfMonth(tok *Token) error {
	if tok.NumberVal < 1 || tok.NumberVal > 31 {
		return p.error("day must be 1-31, got "+p.text(tok), tok.Span.Start, tok.Span.End)
	}
	return nil
}

func (p *parser) checkDayInMonth(tok *Token, month MonthName) error {
	maxDay := 31
	switch month {
	case Feb:
		maxDay = 29
	case Apr, Jun, Sep, Nov:
		maxDay = 30
	}
	if tok.NumberVal > maxDay {
		return p.error(fmt.Sprintf("day must be 1-%d for %s, got %s", maxDay, month, p.text(tok)), tok.Span.Start, tok.Span.End)
	}
	return nil
}

func (p *parser) parseYearRepeat(interval int) (ScheduleExpr, error) {
	if err := p.expect(TokenOn, expectedOn); err != nil {
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
		month := p.advance().MonthNameVal
		day, err := p.parseDayOf(month)
		if err != nil {
			return ScheduleExpr{}, err
		}
		target = NewYearDateTarget(month, day)
	default:
		return ScheduleExpr{}, p.expected(expectedYearTarget)
	}

	if err := p.expect(TokenAt, expectedAt); err != nil {
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
			month, err := p.parseOfMonth()
			if err != nil {
				return YearTarget{}, err
			}
			return NewYearLastWeekdayTarget(month), nil
		case TokenDayName:
			weekday := p.advance().DayNameVal
			month, err := p.parseOfMonth()
			if err != nil {
				return YearTarget{}, err
			}
			return NewYearOrdinalWeekdayTarget(Last, weekday, month), nil
		default:
			return YearTarget{}, p.expected(expectedYearLast)
		}
	case TokenOrdinal:
		ordinal := p.advance().OrdinalVal
		weekday, err := p.parseDayName()
		if err != nil {
			return YearTarget{}, err
		}
		month, err := p.parseOfMonth()
		if err != nil {
			return YearTarget{}, err
		}
		return NewYearOrdinalWeekdayTarget(ordinal, weekday, month), nil
	case TokenOrdinalNumber:
		day, dayToken, err := p.parseOrdinalDay()
		if err != nil {
			return YearTarget{}, err
		}
		month, err := p.parseOfMonth()
		if err != nil {
			return YearTarget{}, err
		}
		if err := p.checkDayInMonth(dayToken, month); err != nil {
			return YearTarget{}, err
		}
		return NewYearDayOfMonthTarget(day, month), nil
	default:
		return YearTarget{}, p.expected(expectedYearThe)
	}
}

func (p *parser) parseOfMonth() (MonthName, error) {
	if err := p.expect(TokenOf, expectedOf); err != nil {
		return 0, err
	}
	return p.parseMonthName()
}

func (p *parser) parseMonthName() (MonthName, error) {
	if p.peekKind() != TokenMonthName {
		return 0, p.expected(expectedMonthName)
	}
	return p.advance().MonthNameVal, nil
}

func (p *parser) parseMonthList() ([]MonthName, error) {
	var months []MonthName
	for {
		month, err := p.parseMonthName()
		if err != nil {
			return nil, err
		}
		months = append(months, month)
		if !p.eat(TokenComma) {
			return months, nil
		}
	}
}

func (p *parser) parseOn() (ScheduleExpr, error) {
	date, err := p.parseDate()
	if err != nil {
		return ScheduleExpr{}, err
	}
	if err := p.expect(TokenAt, expectedAt); err != nil {
		return ScheduleExpr{}, err
	}
	times, err := p.parseTimeList()
	if err != nil {
		return ScheduleExpr{}, err
	}
	return NewSingleDateExpr(date, times), nil
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
		return DayFilter{}, p.expected(expectedDayTarget)
	}
}

func (p *parser) parseDayName() (Weekday, error) {
	if p.peekKind() != TokenDayName {
		return 0, p.expected(expectedDayName)
	}
	return p.advance().DayNameVal, nil
}

func (p *parser) parseDayList() ([]Weekday, error) {
	var days []Weekday
	for {
		day, err := p.parseDayName()
		if err != nil {
			return nil, err
		}
		days = append(days, day)
		if !p.eat(TokenComma) {
			return days, nil
		}
	}
}

func (p *parser) parseTimeList() ([]TimeOfDay, error) {
	var times []TimeOfDay
	for {
		t, err := p.parseTime()
		if err != nil {
			return nil, err
		}
		times = append(times, t)
		if !p.eat(TokenComma) {
			return times, nil
		}
	}
}

func (p *parser) parseTime() (TimeOfDay, error) {
	if p.peekKind() != TokenTime {
		return TimeOfDay{}, p.expected(expectedTime)
	}
	tok := p.advance()
	return TimeOfDay{Hour: tok.TimeHour, Minute: tok.TimeMinute}, nil
}
