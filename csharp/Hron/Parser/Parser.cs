using Hron.Ast;
using Hron.Lexer;

namespace Hron.Parser;

/// <summary>
/// Recursive descent parser for hron expressions.
/// </summary>
public sealed class Parser
{
    private readonly string _input;
    private readonly List<Token> _tokens;
    private int _pos;

    private Parser(string input, List<Token> tokens)
    {
        _input = input;
        _tokens = tokens;
        _pos = 0;
    }

    /// <summary>
    /// Parses an hron expression into a ScheduleData.
    /// </summary>
    public static ScheduleData Parse(string input)
    {
        if (string.IsNullOrWhiteSpace(input))
        {
            throw HronException.Parse("empty input", new Span(0, 0), input ?? "");
        }

        var tokens = Lexer.Lexer.Tokenize(input);
        if (tokens.Count == 0)
        {
            throw HronException.Parse("empty input", new Span(0, 0), input);
        }

        return new Parser(input, tokens).ParseSchedule();
    }

    private ScheduleData ParseSchedule()
    {
        var expr = ParseExpr();

        // Parse optional clauses in order: except, until, starting, during, in
        IReadOnlyList<ExceptionSpec> except = [];
        UntilSpec? until = null;
        string? anchor = null;
        IReadOnlyList<MonthName> during = [];
        string? timezone = null;

        while (_pos < _tokens.Count)
        {
            var tok = _tokens[_pos];
            switch (tok.Kind)
            {
                case TokenKind.Except:
                    if (except.Count > 0)
                        throw ParseError("duplicate except clause", tok.Span);
                    if (until is not null)
                        throw ParseError("wrong clause order: until before except", tok.Span);
                    if (anchor is not null)
                        throw ParseError("wrong clause order: starting before except", tok.Span);
                    if (during.Count > 0)
                        throw ParseError("wrong clause order: during before except", tok.Span);
                    if (timezone is not null)
                        throw ParseError("wrong clause order: in before except", tok.Span);
                    _pos++;
                    except = ParseExceptions();
                    break;

                case TokenKind.Until:
                    if (until is not null)
                        throw ParseError("duplicate until clause", tok.Span);
                    if (anchor is not null)
                        throw ParseError("wrong clause order: starting before until", tok.Span);
                    if (during.Count > 0)
                        throw ParseError("wrong clause order: during before until", tok.Span);
                    if (timezone is not null)
                        throw ParseError("wrong clause order: in before until", tok.Span);
                    _pos++;
                    until = ParseUntil();
                    break;

                case TokenKind.Starting:
                    if (anchor is not null)
                        throw ParseError("duplicate starting clause", tok.Span);
                    if (during.Count > 0)
                        throw ParseError("wrong clause order: during before starting", tok.Span);
                    if (timezone is not null)
                        throw ParseError("wrong clause order: in before starting", tok.Span);
                    _pos++;
                    anchor = ParseStarting();
                    break;

                case TokenKind.During:
                    if (during.Count > 0)
                        throw ParseError("duplicate during clause", tok.Span);
                    if (timezone is not null)
                        throw ParseError("wrong clause order: in before during", tok.Span);
                    _pos++;
                    during = ParseDuring();
                    break;

                case TokenKind.In:
                    _pos++;
                    timezone = ParseTimezone();
                    break;

                default:
                    throw ParseError("unexpected token", tok.Span);
            }
        }

        return new ScheduleData(expr, timezone, except, until, anchor, during);
    }

    private IScheduleExpr ParseExpr()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input", EndSpan());
        }

        return tok.Kind switch
        {
            TokenKind.Every => ParseEveryExpr(),
            TokenKind.On => ParseSingleDate(),
            _ => throw ParseError("expected 'every' or 'on'", tok.Span)
        };
    }

    private IScheduleExpr ParseEveryExpr()
    {
        Expect(TokenKind.Every);

        var next = Peek();
        if (next is null)
        {
            throw ParseError("unexpected end of input after 'every'", EndSpan());
        }

        return next.Kind switch
        {
            TokenKind.Number => ParseEveryNumber(),
            TokenKind.Day or TokenKind.Weekday or TokenKind.Weekend or TokenKind.DayName => ParseDayRepeat(),
            TokenKind.Year => ParseYearRepeat(),
            TokenKind.Month => ParseMonthRepeat(),
            _ => throw ParseError("unexpected token after 'every'", next.Span)
        };
    }

    private IScheduleExpr ParseEveryNumber()
    {
        var numTok = Expect(TokenKind.Number);
        var interval = numTok.NumberVal;

        if (interval == 0)
        {
            throw ParseError("zero interval", numTok.Span);
        }

        var next = Peek();
        if (next is null)
        {
            throw ParseError("unexpected end of input after number", EndSpan());
        }

        return next.Kind switch
        {
            TokenKind.IntervalUnit => ParseIntervalRepeat(interval),
            TokenKind.Day => ParseDayWithInterval(interval),
            TokenKind.Weeks => ParseWeeksWithInterval(interval),
            TokenKind.Month => ParseMonthWithInterval(interval),
            TokenKind.Year => ParseYearWithInterval(interval),
            _ => throw ParseError("expected unit (min/hours/day/weeks/month/year) after number", next.Span)
        };
    }

    private IScheduleExpr ParseDayWithInterval(int interval)
    {
        _pos++;
        var days = DayFilter.Every();
        var times = ParseAtTimes();
        return new DayRepeat(interval, days, times);
    }

    private IScheduleExpr ParseWeeksWithInterval(int interval)
    {
        _pos++;
        Expect(TokenKind.On);
        var weekDays = ParseDayList();
        var times = ParseAtTimes();
        return new WeekRepeat(interval, weekDays, times);
    }

    private IScheduleExpr ParseMonthWithInterval(int interval)
    {
        _pos++;
        Expect(TokenKind.On);
        Expect(TokenKind.The);
        var target = ParseMonthTarget();
        var times = ParseAtTimes();
        return new MonthRepeat(interval, target, times);
    }

    private IScheduleExpr ParseYearWithInterval(int interval)
    {
        _pos++;
        Expect(TokenKind.On);
        var target = ParseYearTarget();
        var times = ParseAtTimes();
        return new YearRepeat(interval, target, times);
    }

    private IScheduleExpr ParseDayRepeat()
    {
        var days = ParseDayFilter();
        var times = ParseAtTimes();
        return new DayRepeat(1, days, times);
    }

    private DayFilter ParseDayFilter()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input", EndSpan());
        }

        return tok.Kind switch
        {
            TokenKind.Day => AdvanceAndReturn(DayFilter.Every()),
            TokenKind.Weekday => AdvanceAndReturn(DayFilter.Weekday()),
            TokenKind.Weekend => AdvanceAndReturn(DayFilter.Weekend()),
            TokenKind.DayName => DayFilter.SpecificDays(ParseDayList()),
            _ => throw ParseError("expected day filter", tok.Span)
        };
    }

    private T AdvanceAndReturn<T>(T value)
    {
        _pos++;
        return value;
    }

    private IReadOnlyList<Weekday> ParseDayList()
    {
        var days = new List<Weekday>();

        var tok = Expect(TokenKind.DayName);
        days.Add(tok.DayNameVal!.Value);

        while (Check(TokenKind.Comma))
        {
            _pos++;
            tok = Expect(TokenKind.DayName);
            days.Add(tok.DayNameVal!.Value);
        }

        return days;
    }

    private IScheduleExpr ParseIntervalRepeat(int interval)
    {
        var unitTok = Expect(TokenKind.IntervalUnit);
        var unit = unitTok.UnitVal!.Value;

        Expect(TokenKind.From);
        var fromTime = ParseTime();
        Expect(TokenKind.To);
        var toTime = ParseTime();

        DayFilter? dayFilter = null;
        if (Check(TokenKind.On))
        {
            _pos++;
            dayFilter = ParseDayFilterForInterval();
        }

        return new IntervalRepeat(interval, unit, fromTime, toTime, dayFilter);
    }

    private DayFilter ParseDayFilterForInterval()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'on'", EndSpan());
        }

        return tok.Kind switch
        {
            TokenKind.Day => AdvanceAndReturn(DayFilter.Every()),
            TokenKind.Weekday => AdvanceAndReturn(DayFilter.Weekday()),
            TokenKind.Weekend => AdvanceAndReturn(DayFilter.Weekend()),
            TokenKind.DayName => DayFilter.SpecificDays(ParseDayList()),
            _ => throw ParseError("expected day filter after 'on'", tok.Span)
        };
    }

    private IScheduleExpr ParseMonthRepeat()
    {
        Expect(TokenKind.Month);
        Expect(TokenKind.On);
        Expect(TokenKind.The);

        var target = ParseMonthTarget();
        var times = ParseAtTimes();

        return new MonthRepeat(1, target, times);
    }

    private MonthTarget ParseMonthTarget()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input", EndSpan());
        }

        if (tok.Kind == TokenKind.Last)
        {
            _pos++;
            var next = Peek();
            if (next is not null && next.Kind == TokenKind.Day)
            {
                _pos++;
                return MonthTarget.LastDay();
            }
            if (next is not null && next.Kind == TokenKind.Weekday)
            {
                _pos++;
                return MonthTarget.LastWeekday();
            }
            if (next is not null && next.Kind == TokenKind.DayName)
            {
                var weekday = _tokens[_pos++].DayNameVal!.Value;
                return MonthTarget.OrdinalWeekday(OrdinalPosition.Last, weekday);
            }
            throw ParseError("expected 'day', 'weekday', or day name after 'last'", next?.Span ?? EndSpan());
        }

        // Check for ordinal + day name (e.g., "first monday")
        if (tok.Kind == TokenKind.Ordinal)
        {
            var ordinal = _tokens[_pos++].OrdinalVal!.Value;
            var dayTok = Expect(TokenKind.DayName);
            return MonthTarget.OrdinalWeekday(ordinal, dayTok.DayNameVal!.Value);
        }

        // Check for [next|previous] nearest weekday to <day>
        if (tok.Kind == TokenKind.Next || tok.Kind == TokenKind.Previous || tok.Kind == TokenKind.Nearest)
        {
            return ParseNearestWeekdayTarget();
        }

        // Parse day specs (single or range)
        var specs = ParseDayOfMonthSpecs();
        return MonthTarget.Days(specs);
    }

    private MonthTarget ParseNearestWeekdayTarget()
    {
        NearestDirection? direction = null;
        var tok = Peek();

        // Optional direction: "next" or "previous"
        if (tok is not null && tok.Kind == TokenKind.Next)
        {
            _pos++;
            direction = NearestDirection.Next;
        }
        else if (tok is not null && tok.Kind == TokenKind.Previous)
        {
            _pos++;
            direction = NearestDirection.Previous;
        }

        Expect(TokenKind.Nearest);
        Expect(TokenKind.Weekday);
        Expect(TokenKind.To);

        var dayTok = Expect(TokenKind.OrdinalNumber);
        var day = dayTok.NumberVal;
        if (day < 1 || day > 31)
        {
            throw ParseError($"invalid day number {day} (must be 1-31)", dayTok.Span);
        }

        return MonthTarget.NearestWeekday(day, direction);
    }

    private IReadOnlyList<DayOfMonthSpec> ParseDayOfMonthSpecs()
    {
        var specs = new List<DayOfMonthSpec> { ParseDayOfMonthSpec() };

        while (Check(TokenKind.Comma))
        {
            _pos++;
            specs.Add(ParseDayOfMonthSpec());
        }

        return specs;
    }

    private DayOfMonthSpec ParseDayOfMonthSpec()
    {
        var tok = Expect(TokenKind.OrdinalNumber);
        var start = tok.NumberVal;

        if (start < 1 || start > 31)
        {
            throw ParseError($"invalid day number {start} (must be 1-31)", tok.Span);
        }

        if (Check(TokenKind.To))
        {
            _pos++;
            var endTok = Expect(TokenKind.OrdinalNumber);
            var end = endTok.NumberVal;
            if (end < 1 || end > 31)
            {
                throw ParseError($"invalid day number {end} (must be 1-31)", endTok.Span);
            }
            if (start > end)
            {
                throw ParseError($"invalid day range: {start} to {end} (start must be <= end)", tok.Span);
            }
            return DayOfMonthSpec.Range(start, end);
        }

        return DayOfMonthSpec.Single(start);
    }

    private IScheduleExpr ParseYearRepeat()
    {
        Expect(TokenKind.Year);
        Expect(TokenKind.On);

        var target = ParseYearTarget();
        var times = ParseAtTimes();

        return new YearRepeat(1, target, times);
    }

    private YearTarget ParseYearTarget()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'on'", EndSpan());
        }

        // Check for "the" (ordinal weekday, day of month, or last weekday)
        if (tok.Kind == TokenKind.The)
        {
            _pos++;
            return ParseYearTargetAfterThe();
        }

        // Named date: month day (e.g., dec 25)
        var monthTok = Expect(TokenKind.MonthName);
        var dayTok = ParseDayNumber();
        ValidateNamedDate(monthTok.MonthNameVal!.Value, dayTok.NumberVal, dayTok.Span);
        return YearTarget.Date(monthTok.MonthNameVal!.Value, dayTok.NumberVal);
    }

    private YearTarget ParseYearTargetAfterThe()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'the'", EndSpan());
        }

        // "the last ..."
        if (tok.Kind == TokenKind.Last)
        {
            _pos++;
            var next = Peek();
            if (next is not null && next.Kind == TokenKind.DayName)
            {
                // "the last friday of month"
                var weekday = _tokens[_pos++].DayNameVal!.Value;
                Expect(TokenKind.Of);
                var monthTok = Expect(TokenKind.MonthName);
                return YearTarget.OrdinalWeekday(OrdinalPosition.Last, weekday, monthTok.MonthNameVal!.Value);
            }
            if (next is not null && next.Kind == TokenKind.Weekday)
            {
                // "the last weekday of month"
                _pos++;
                Expect(TokenKind.Of);
                var monthTok = Expect(TokenKind.MonthName);
                return YearTarget.LastWeekday(monthTok.MonthNameVal!.Value);
            }
            throw ParseError("expected day name or 'weekday' after 'last'", next?.Span ?? EndSpan());
        }

        // "the first/second/... weekday of month"
        if (tok.Kind == TokenKind.Ordinal)
        {
            var ordinal = _tokens[_pos++].OrdinalVal!.Value;
            var dayTok = Expect(TokenKind.DayName);
            Expect(TokenKind.Of);
            var monthTok = Expect(TokenKind.MonthName);
            return YearTarget.OrdinalWeekday(ordinal, dayTok.DayNameVal!.Value, monthTok.MonthNameVal!.Value);
        }

        // "the 15th of month"
        if (tok.Kind == TokenKind.OrdinalNumber)
        {
            var day = _tokens[_pos++].NumberVal;
            Expect(TokenKind.Of);
            var monthTok = Expect(TokenKind.MonthName);
            ValidateNamedDate(monthTok.MonthNameVal!.Value, day, tok.Span);
            return YearTarget.DayOfMonth(day, monthTok.MonthNameVal!.Value);
        }

        throw ParseError("expected ordinal, ordinal number, or 'last' after 'the'", tok.Span);
    }

    private IScheduleExpr ParseSingleDate()
    {
        Expect(TokenKind.On);

        var dateSpec = ParseDateSpec();
        var times = ParseAtTimes();

        return new SingleDate(dateSpec, times);
    }

    private void ValidateIsoDate(string dateStr, Span span)
    {
        if (!DateOnly.TryParseExact(dateStr, "yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out _))
        {
            throw ParseError($"invalid date: {dateStr}", span);
        }
    }

    private DateSpec ParseDateSpec()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input", EndSpan());
        }

        if (tok.Kind == TokenKind.IsoDate)
        {
            ValidateIsoDate(tok.IsoDateVal!, tok.Span);
            _pos++;
            return DateSpec.Iso(tok.IsoDateVal!);
        }

        var monthTok = Expect(TokenKind.MonthName);
        var dayTok = ParseDayNumber();
        ValidateNamedDate(monthTok.MonthNameVal!.Value, dayTok.NumberVal, dayTok.Span);
        return DateSpec.Named(monthTok.MonthNameVal!.Value, dayTok.NumberVal);
    }

    private IReadOnlyList<TimeOfDay> ParseAtTimes()
    {
        Expect(TokenKind.At);
        return ParseTimeList();
    }

    private IReadOnlyList<TimeOfDay> ParseTimeList()
    {
        var times = new List<TimeOfDay> { ParseTime() };

        while (Check(TokenKind.Comma))
        {
            _pos++;
            times.Add(ParseTime());
        }

        return times;
    }

    private TimeOfDay ParseTime()
    {
        var tok = Expect(TokenKind.Time);
        return new TimeOfDay(tok.TimeHour, tok.TimeMinute);
    }

    private IReadOnlyList<ExceptionSpec> ParseExceptions()
    {
        var exceptions = new List<ExceptionSpec> { ParseExceptionSpec() };

        while (Check(TokenKind.Comma))
        {
            _pos++;
            exceptions.Add(ParseExceptionSpec());
        }

        return exceptions;
    }

    private ExceptionSpec ParseExceptionSpec()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'except'", EndSpan());
        }

        if (tok.Kind == TokenKind.IsoDate)
        {
            ValidateIsoDate(tok.IsoDateVal!, tok.Span);
            _pos++;
            return ExceptionSpec.Iso(tok.IsoDateVal!);
        }

        var monthTok = Expect(TokenKind.MonthName);
        var dayTok = ParseDayNumber();
        ValidateNamedDate(monthTok.MonthNameVal!.Value, dayTok.NumberVal, dayTok.Span);
        return ExceptionSpec.Named(monthTok.MonthNameVal!.Value, dayTok.NumberVal);
    }

    private UntilSpec ParseUntil()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'until'", EndSpan());
        }

        if (tok.Kind == TokenKind.IsoDate)
        {
            ValidateIsoDate(tok.IsoDateVal!, tok.Span);
            _pos++;
            return UntilSpec.Iso(tok.IsoDateVal!);
        }

        var monthTok = Expect(TokenKind.MonthName);
        var dayTok = ParseDayNumber();
        ValidateNamedDate(monthTok.MonthNameVal!.Value, dayTok.NumberVal, dayTok.Span);
        return UntilSpec.Named(monthTok.MonthNameVal!.Value, dayTok.NumberVal);
    }

    private string ParseStarting()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("unexpected end of input after 'starting'", EndSpan());
        }

        if (tok.Kind == TokenKind.IsoDate)
        {
            ValidateIsoDate(tok.IsoDateVal!, tok.Span);
            _pos++;
            return tok.IsoDateVal!;
        }

        throw ParseError("starting only accepts ISO dates", tok.Span);
    }

    private IReadOnlyList<MonthName> ParseDuring()
    {
        var months = new List<MonthName>();

        var tok = Expect(TokenKind.MonthName);
        months.Add(tok.MonthNameVal!.Value);

        while (Check(TokenKind.Comma))
        {
            _pos++;
            tok = Expect(TokenKind.MonthName);
            months.Add(tok.MonthNameVal!.Value);
        }

        return months;
    }

    private string ParseTimezone()
    {
        var tok = Peek();
        if (tok is null || tok.Kind != TokenKind.Timezone)
        {
            throw ParseError("expected timezone after 'in'", tok?.Span ?? EndSpan());
        }
        _pos++;
        return tok.TimezoneVal!;
    }

    // Helper methods

    private static readonly int[] MaxDays = [0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    private void ValidateNamedDate(MonthName month, int day, Span span)
    {
        var maxDay = MaxDays[(int)month];
        if (day < 1 || day > maxDay)
        {
            throw ParseError($"invalid day {day} for {month.ToDisplayString()} (max {maxDay})", span);
        }
    }

    private Token ParseDayNumber()
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError("expected day number but reached end of input", EndSpan());
        }
        if (tok.Kind != TokenKind.Number && tok.Kind != TokenKind.OrdinalNumber)
        {
            throw ParseError($"expected day number but got {tok.Kind}", tok.Span);
        }
        _pos++;
        var day = tok.NumberVal;
        if (day < 1 || day > 31)
        {
            throw ParseError($"invalid day number {day} (must be 1-31)", tok.Span);
        }
        return tok;
    }

    private Token? Peek() => _pos < _tokens.Count ? _tokens[_pos] : null;

    private bool Check(TokenKind kind)
    {
        var tok = Peek();
        return tok is not null && tok.Kind == kind;
    }

    private Token Expect(TokenKind kind)
    {
        var tok = Peek();
        if (tok is null)
        {
            throw ParseError($"expected {kind} but reached end of input", EndSpan());
        }
        if (tok.Kind != kind)
        {
            throw ParseError($"expected {kind} but got {tok.Kind}", tok.Span);
        }
        _pos++;
        return tok;
    }

    private Span EndSpan()
    {
        if (_tokens.Count == 0)
        {
            return new Span(0, 0);
        }
        var lastSpan = _tokens[^1].Span;
        return new Span(lastSpan.End, lastSpan.End);
    }

    private HronException ParseError(string message, Span span)
        => HronException.Parse(message, span, _input);
}
