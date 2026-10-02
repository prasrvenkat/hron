using Hron.Ast;
using Hron.Lexer;
using static System.FormattableString;

namespace Hron.Parser;

internal sealed class Parser
{
    /// <summary>
    /// The <c>{what}</c> of each <c>expected {what}, got ...</c> error, one per phrase in the
    /// position table of spec/README.md, "Parse errors".
    /// </summary>
    private static class Expected
    {
        public const string EveryOrOn = "'every' or 'on'";
        public const string Repeater = "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number";
        public const string Unit = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')";
        public const string At = "'at'";
        public const string Time = "a time (HH:MM)";
        public const string From = "'from'";
        public const string To = "'to'";
        public const string DayTarget = "'day', 'weekday', 'weekend' or a day name";
        public const string On = "'on'";
        public const string DayName = "a day name";
        public const string The = "'the'";
        public const string MonthTarget = "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'";
        public const string MonthLast = "'day', 'weekday' or a day name";
        public const string Nearest = "'nearest'";
        public const string Weekday = "'weekday'";
        public const string DayOfMonth = "a day such as 15th";
        public const string YearTarget = "a month name or 'the'";
        public const string YearThe = "a day such as 15th, 'last' or an ordinal such as 'first'";
        public const string YearLast = "'weekday' or a day name";
        public const string Of = "'of'";
        public const string MonthName = "a month name";
        public const string DayNumber = "a day number";
        public const string Date = "a date (YYYY-MM-DD, or a month and day)";
        public const string IsoDate = "a date (YYYY-MM-DD)";
        public const string Timezone = "a timezone";
    }

    private static readonly (TokenKind Kind, string Keyword)[] ClauseOrder =
    [
        (TokenKind.Except, "except"),
        (TokenKind.Until, "until"),
        (TokenKind.Starting, "starting"),
        (TokenKind.During, "during"),
        (TokenKind.In, "in"),
    ];

    private static readonly int[] MaxDays = [0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

    private readonly string _input;
    private readonly List<Token> _tokens;
    private int _pos;

    private Parser(string input, List<Token> tokens)
    {
        _input = input;
        _tokens = tokens;
    }

    public static ScheduleData Parse(string input)
    {
        var tokens = Lexer.Lexer.Tokenize(input);
        if (tokens.Count == 0)
        {
            throw HronException.Parse("empty expression", new Span(0, 0), input);
        }

        var parser = new Parser(input, tokens);
        var expr = parser.ParseExpression();
        var (schedule, untilOffsets) = parser.ParseClauses(expr);
        if (parser.Peek() is not null)
        {
            throw parser.Leftover(schedule);
        }
        // spec/README.md, "Parse errors": every other error wins over a named until without starting.
        parser.CheckNamedUntil(schedule, untilOffsets);
        return schedule;
    }

    private IScheduleExpr ParseExpression()
    {
        if (Eat(TokenKind.Every))
        {
            return ParseEvery();
        }
        if (Eat(TokenKind.On))
        {
            return ParseSingleDate();
        }
        throw ExpectedError(Expected.EveryOrOn);
    }

    private (ScheduleData Schedule, Span? UntilSpan) ParseClauses(IScheduleExpr expr)
    {
        var schedule = ScheduleData.Of(expr);
        Span? untilOffsets = null;

        if (Eat(TokenKind.Except))
        {
            schedule = schedule.WithExcept(ParseExceptions());
        }

        if (Peek() is { Kind: TokenKind.Until } untilToken)
        {
            _pos++;
            var date = ParseDate();
            schedule = schedule.WithUntil(date.Kind == DateSpecKind.Iso
                ? UntilSpec.Iso(date.Date!)
                : UntilSpec.Named(date.Month!.Value, date.Day));
            untilOffsets = new Span(untilToken.Span.Start, Previous().Span.End);
        }

        if (Eat(TokenKind.Starting))
        {
            var token = Peek() is { Kind: TokenKind.IsoDate } iso ? iso : throw ExpectedError(Expected.IsoDate);
            _pos++;
            schedule = schedule.WithStarting(CheckIsoDate(token));
        }

        if (Eat(TokenKind.During))
        {
            schedule = schedule.WithDuring(ParseMonthList());
        }

        if (Eat(TokenKind.In))
        {
            var token = Peek() is { Kind: TokenKind.Timezone } zone ? zone : throw ExpectedError(Expected.Timezone);
            _pos++;
            schedule = schedule.WithTimezone(CheckTimezone(token));
        }

        return (schedule, untilOffsets);
    }

    private HronException Leftover(ScheduleData schedule)
    {
        var token = _tokens[_pos];
        // Every clause holds at least one item, so a clause was read exactly when its field is set.
        bool[] read =
        [
            schedule.Except.Count > 0,
            schedule.Until is not null,
            schedule.Starting is not null,
            schedule.During.Count > 0,
            schedule.Timezone is not null,
        ];
        var clause = Array.FindIndex(ClauseOrder, c => c.Kind == token.Kind);
        var lastRead = Array.LastIndexOf(read, true);
        var message = clause >= 0 && read[clause] ? $"duplicate '{ClauseOrder[clause].Keyword}' clause"
            : clause >= 0 && lastRead >= 0 ? $"'{ClauseOrder[clause].Keyword}' must come before '{ClauseOrder[lastRead].Keyword}'"
            : $"unexpected '{Text(token)}' after the schedule";
        return Error(message, token, token);
    }

    private void CheckNamedUntil(ScheduleData schedule, Span? untilOffsets)
    {
        if (schedule.Until is { Kind: UntilSpecKind.Named } until && schedule.Starting is null && untilOffsets is { } span)
        {
            var month = until.Month!.Value.ToDisplayString();
            throw HronException.Parse(
                Invariant($"until {month} {until.Day} has no year: add a starting date, or use an ISO date"),
                Span.FromUtf16Range(_input, span.Start, span.End),
                _input,
                Invariant($"until {month} {until.Day} starting YYYY-MM-DD"));
        }
    }

    private IReadOnlyList<ExceptionSpec> ParseExceptions()
    {
        var exceptions = new List<ExceptionSpec> { ParseException() };
        while (Eat(TokenKind.Comma))
        {
            exceptions.Add(ParseException());
        }
        return exceptions;
    }

    private ExceptionSpec ParseException()
    {
        var date = ParseDate();
        return date.Kind == DateSpecKind.Iso
            ? ExceptionSpec.Iso(date.Date!)
            : ExceptionSpec.Named(date.Month!.Value, date.Day);
    }

    private DateSpec ParseDate()
    {
        switch (Peek())
        {
            case { Kind: TokenKind.IsoDate } token:
                _pos++;
                return DateSpec.Iso(CheckIsoDate(token));
            case { Kind: TokenKind.MonthName } token:
                _pos++;
                var month = token.MonthNameVal!.Value;
                return DateSpec.Named(month, ParseDayOf(month));
            default:
                throw ExpectedError(Expected.Date);
        }
    }

    private string CheckIsoDate(Token token)
    {
        var text = Text(token);
        if (!IsoDate.TryParse(text, out _))
        {
            throw Error($"date must be a calendar date from 0001-01-01 to 9999-12-31, got {text}", token, token);
        }
        return text;
    }

    private string CheckTimezone(Token token)
    {
        var name = Text(token);
        return TimezoneNames.Canonical(name)
            ?? throw Error($"timezone must be UTC or an Area/Location name such as America/New_York, got {name}", token, token);
    }

    private IScheduleExpr ParseEvery()
    {
        var token = Peek();
        switch (token?.Kind)
        {
            case TokenKind.Day:
                _pos++;
                return ParseDayRepeat(1, DayFilter.Every());
            case TokenKind.Weekday:
                _pos++;
                return ParseDayRepeat(1, DayFilter.Weekday());
            case TokenKind.Weekend:
                _pos++;
                return ParseDayRepeat(1, DayFilter.Weekend());
            case TokenKind.DayName:
                return ParseDayRepeat(1, DayFilter.SpecificDays(ParseDayList()));
            case TokenKind.Weeks:
                _pos++;
                return ParseWeekRepeat(1);
            case TokenKind.Month:
                _pos++;
                return ParseMonthRepeat(1);
            case TokenKind.Year:
                _pos++;
                return ParseYearRepeat(1);
            case TokenKind.Number:
                return ParseNumberRepeat(token!);
            default:
                throw ExpectedError(Expected.Repeater);
        }
    }

    private IScheduleExpr ParseDayRepeat(int interval, DayFilter days)
    {
        Expect(TokenKind.At, Expected.At);
        return new DayRepeat(interval, days, ParseTimeList());
    }

    private IScheduleExpr ParseNumberRepeat(Token number)
    {
        _pos++;
        var interval = number.NumberVal;
        if (interval == 0)
        {
            throw Error($"interval must be 1-2147483647, got {Text(number)}", number, number);
        }

        var token = Peek();
        switch (token?.Kind)
        {
            case TokenKind.Weeks:
                _pos++;
                return ParseWeekRepeat(interval);
            case TokenKind.IntervalUnit:
                _pos++;
                return ParseIntervalRepeat(interval, token!.UnitVal!.Value);
            case TokenKind.Day:
                _pos++;
                return ParseDayRepeat(interval, DayFilter.Every());
            case TokenKind.Month:
                _pos++;
                return ParseMonthRepeat(interval);
            case TokenKind.Year:
                _pos++;
                return ParseYearRepeat(interval);
            default:
                throw ExpectedError(Expected.Unit);
        }
    }

    private IScheduleExpr ParseIntervalRepeat(int interval, IntervalUnit unit)
    {
        Expect(TokenKind.From, Expected.From);
        var from = ParseTime();
        var fromToken = Previous();
        Expect(TokenKind.To, Expected.To);
        var to = ParseTime();
        var toToken = Previous();
        if (from.TotalMinutes > to.TotalMinutes)
        {
            throw Error(
                $"time window must not run backwards: {Text(fromToken)} to {Text(toToken)} (a window cannot cross midnight)",
                fromToken,
                toToken);
        }

        var dayFilter = Eat(TokenKind.On) ? ParseDayTarget() : null;
        return new IntervalRepeat(interval, unit, from, to, dayFilter);
    }

    private IScheduleExpr ParseWeekRepeat(int interval)
    {
        Expect(TokenKind.On, Expected.On);
        var days = ParseDayList();
        Expect(TokenKind.At, Expected.At);
        return new WeekRepeat(interval, days, ParseTimeList());
    }

    private IScheduleExpr ParseMonthRepeat(int interval)
    {
        Expect(TokenKind.On, Expected.On);
        Expect(TokenKind.The, Expected.The);

        MonthTarget target;
        var token = Peek();
        switch (token?.Kind)
        {
            case TokenKind.Last:
                _pos++;
                var last = Peek();
                target = last?.Kind switch
                {
                    TokenKind.Day => MonthTarget.LastDay(),
                    TokenKind.Weekday => MonthTarget.LastWeekday(),
                    TokenKind.DayName => MonthTarget.OrdinalWeekday(OrdinalPosition.Last, last!.DayNameVal!.Value),
                    _ => throw ExpectedError(Expected.MonthLast),
                };
                _pos++;
                break;
            case TokenKind.Ordinal:
                _pos++;
                target = MonthTarget.OrdinalWeekday(token!.OrdinalVal!.Value, ParseDayName());
                break;
            case TokenKind.OrdinalNumber:
                target = MonthTarget.Days(ParseOrdinalDayList());
                break;
            case TokenKind.Next or TokenKind.Previous or TokenKind.Nearest:
                target = ParseNearestWeekdayTarget();
                break;
            default:
                throw ExpectedError(Expected.MonthTarget);
        }

        Expect(TokenKind.At, Expected.At);
        return new MonthRepeat(interval, target, ParseTimeList());
    }

    private MonthTarget ParseNearestWeekdayTarget()
    {
        NearestDirection? direction = Eat(TokenKind.Next) ? NearestDirection.Next
            : Eat(TokenKind.Previous) ? NearestDirection.Previous
            : null;
        Expect(TokenKind.Nearest, Expected.Nearest);
        Expect(TokenKind.Weekday, Expected.Weekday);
        Expect(TokenKind.To, Expected.To);
        var (day, _) = ParseOrdinalDay();
        return MonthTarget.NearestWeekday(day, direction);
    }

    private IReadOnlyList<DayOfMonthSpec> ParseOrdinalDayList()
    {
        var specs = new List<DayOfMonthSpec> { ParseOrdinalDaySpec() };
        while (Eat(TokenKind.Comma))
        {
            specs.Add(ParseOrdinalDaySpec());
        }
        return specs;
    }

    private DayOfMonthSpec ParseOrdinalDaySpec()
    {
        var (start, startToken) = ParseOrdinalDay();
        if (!Eat(TokenKind.To))
        {
            return DayOfMonthSpec.Single(start);
        }
        var (end, endToken) = ParseOrdinalDay();
        if (start > end)
        {
            throw Error($"day range must not run backwards: {Text(startToken)} to {Text(endToken)}", startToken, endToken);
        }
        return DayOfMonthSpec.Range(start, end);
    }

    private (int Day, Token Token) ParseOrdinalDay()
    {
        var token = Peek() is { Kind: TokenKind.OrdinalNumber } day ? day : throw ExpectedError(Expected.DayOfMonth);
        _pos++;
        return (CheckDayOfMonth(token), token);
    }

    private int ParseDayOf(MonthName month)
    {
        var token = Peek() is { Kind: TokenKind.Number or TokenKind.OrdinalNumber } day
            ? day
            : throw ExpectedError(Expected.DayNumber);
        _pos++;
        var value = CheckDayOfMonth(token);
        CheckDayInMonth(value, token, month);
        return value;
    }

    private int CheckDayOfMonth(Token token)
    {
        if (token.NumberVal is < 1 or > 31)
        {
            throw Error($"day must be 1-31, got {Text(token)}", token, token);
        }
        return token.NumberVal;
    }

    private void CheckDayInMonth(int day, Token token, MonthName month)
    {
        var max = MaxDays[(int)month];
        if (day > max)
        {
            throw Error(Invariant($"day must be 1-{max} for {month.ToDisplayString()}, got {Text(token)}"), token, token);
        }
    }

    private IScheduleExpr ParseYearRepeat(int interval)
    {
        Expect(TokenKind.On, Expected.On);

        YearTarget target;
        switch (Peek())
        {
            case { Kind: TokenKind.The }:
                _pos++;
                target = ParseYearTargetAfterThe();
                break;
            case { Kind: TokenKind.MonthName } token:
                _pos++;
                var month = token.MonthNameVal!.Value;
                target = YearTarget.Date(month, ParseDayOf(month));
                break;
            default:
                throw ExpectedError(Expected.YearTarget);
        }

        Expect(TokenKind.At, Expected.At);
        return new YearRepeat(interval, target, ParseTimeList());
    }

    private YearTarget ParseYearTargetAfterThe()
    {
        var token = Peek();
        switch (token?.Kind)
        {
            case TokenKind.Last:
                _pos++;
                var last = Peek();
                switch (last?.Kind)
                {
                    case TokenKind.Weekday:
                        _pos++;
                        Expect(TokenKind.Of, Expected.Of);
                        return YearTarget.LastWeekday(ParseMonthName());
                    case TokenKind.DayName:
                        _pos++;
                        Expect(TokenKind.Of, Expected.Of);
                        return YearTarget.OrdinalWeekday(OrdinalPosition.Last, last!.DayNameVal!.Value, ParseMonthName());
                    default:
                        throw ExpectedError(Expected.YearLast);
                }
            case TokenKind.Ordinal:
                _pos++;
                var weekday = ParseDayName();
                Expect(TokenKind.Of, Expected.Of);
                return YearTarget.OrdinalWeekday(token!.OrdinalVal!.Value, weekday, ParseMonthName());
            case TokenKind.OrdinalNumber:
                var (day, dayToken) = ParseOrdinalDay();
                Expect(TokenKind.Of, Expected.Of);
                var month = ParseMonthName();
                CheckDayInMonth(day, dayToken, month);
                return YearTarget.DayOfMonth(day, month);
            default:
                throw ExpectedError(Expected.YearThe);
        }
    }

    private MonthName ParseMonthName()
    {
        var token = Peek() is { Kind: TokenKind.MonthName } month ? month : throw ExpectedError(Expected.MonthName);
        _pos++;
        return token.MonthNameVal!.Value;
    }

    private IReadOnlyList<MonthName> ParseMonthList()
    {
        var months = new List<MonthName> { ParseMonthName() };
        while (Eat(TokenKind.Comma))
        {
            months.Add(ParseMonthName());
        }
        return months;
    }

    private IScheduleExpr ParseSingleDate()
    {
        var date = ParseDate();
        Expect(TokenKind.At, Expected.At);
        return new SingleDate(date, ParseTimeList());
    }

    private DayFilter ParseDayTarget()
    {
        switch (Peek()?.Kind)
        {
            case TokenKind.Day:
                _pos++;
                return DayFilter.Every();
            case TokenKind.Weekday:
                _pos++;
                return DayFilter.Weekday();
            case TokenKind.Weekend:
                _pos++;
                return DayFilter.Weekend();
            case TokenKind.DayName:
                return DayFilter.SpecificDays(ParseDayList());
            default:
                throw ExpectedError(Expected.DayTarget);
        }
    }

    private Weekday ParseDayName()
    {
        var token = Peek() is { Kind: TokenKind.DayName } day ? day : throw ExpectedError(Expected.DayName);
        _pos++;
        return token.DayNameVal!.Value;
    }

    private IReadOnlyList<Weekday> ParseDayList()
    {
        var days = new List<Weekday> { ParseDayName() };
        while (Eat(TokenKind.Comma))
        {
            days.Add(ParseDayName());
        }
        return days;
    }

    private IReadOnlyList<TimeOfDay> ParseTimeList()
    {
        var times = new List<TimeOfDay> { ParseTime() };
        while (Eat(TokenKind.Comma))
        {
            times.Add(ParseTime());
        }
        return times;
    }

    private TimeOfDay ParseTime()
    {
        var token = Peek() is { Kind: TokenKind.Time } time ? time : throw ExpectedError(Expected.Time);
        _pos++;
        return new TimeOfDay(token.TimeHour, token.TimeMinute);
    }

    private Token? Peek() => _pos < _tokens.Count ? _tokens[_pos] : null;

    private Token Previous() => _tokens[_pos - 1];

    private bool Eat(TokenKind kind)
    {
        var found = Peek()?.Kind == kind;
        if (found)
        {
            _pos++;
        }
        return found;
    }

    private void Expect(TokenKind kind, string what)
    {
        if (!Eat(kind))
        {
            throw ExpectedError(what);
        }
    }

    private string Text(Token token) => _input[token.Span.Start..token.Span.End];

    private HronException Error(string message, Token first, Token last)
        => HronException.Parse(message, Span.FromUtf16Range(_input, first.Span.Start, last.Span.End), _input);

    private HronException ExpectedError(string what)
    {
        if (Peek() is { } token)
        {
            return Error($"expected {what}, got '{Text(token)}'", token, token);
        }
        var end = _tokens[^1].Span.End;
        return HronException.Parse($"expected {what}, got end of input", Span.FromUtf16Range(_input, end, end), _input);
    }
}
