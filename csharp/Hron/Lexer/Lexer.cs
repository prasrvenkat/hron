using System.Globalization;
using Hron.Ast;

namespace Hron.Lexer;

internal sealed class Lexer
{
    private const int MaxNumber = int.MaxValue;

    private readonly string _input;
    private int _pos;

    private Lexer(string input)
    {
        _input = input;
    }

    public static List<Token> Tokenize(string input)
        => new Lexer(input).DoTokenize();

    private List<Token> DoTokenize()
    {
        var tokens = new List<Token>();
        while (true)
        {
            AdvanceWhile(IsWhitespace);
            if (_pos >= _input.Length)
            {
                break;
            }

            var start = _pos;
            var ch = _input[_pos];
            if (tokens.Count > 0 && tokens[^1].Kind == TokenKind.In)
            {
                AdvanceWhile(c => !IsWhitespace(c));
                tokens.Add(Token.Timezone(_input[start.._pos], new Span(start, _pos)));
            }
            else if (ch == ',')
            {
                _pos++;
                tokens.Add(Token.Comma(new Span(start, _pos)));
            }
            else if (IsAlpha(ch))
            {
                tokens.Add(LexWord(start));
            }
            else if (IsDigit(ch))
            {
                tokens.Add(LexDigits(start));
            }
            else
            {
                throw UnexpectedCharacter(start);
            }
        }

        return tokens;
    }

    private void AdvanceWhile(Func<char, bool> matches)
    {
        while (_pos < _input.Length && matches(_input[_pos]))
        {
            _pos++;
        }
    }

    private HronException Error(string message, int start)
        => HronException.Lex(message, Span.FromUtf16Range(_input, start, _pos), _input);

    private Token LexWord(int start)
    {
        AdvanceWhile(c => IsAlphanumeric(c) || c == '_');
        var word = _input[start.._pos];
        if (!KeywordMap.TryGetValue(AsciiLower(word), out var template))
        {
            throw Error($"unknown keyword '{word}'", start);
        }
        return template with { Span = new Span(start, _pos) };
    }

    private Token LexDigits(int start)
    {
        AdvanceWhile(IsDigit);
        var digitsEnd = _pos;
        if (digitsEnd - start == 4 && IsIsoDateTail())
        {
            _pos += "-MM-DD".Length;
            return Token.IsoDate(_input[start.._pos], new Span(start, _pos));
        }
        if (_pos < _input.Length && _input[_pos] == ':')
        {
            return LexTime(start);
        }

        var value = NumberValue(start, digitsEnd) ?? throw Error("number must be at most 2147483647", start);
        if (_pos + 2 <= _input.Length && AsciiLower(_input.Substring(_pos, 2)) is "st" or "nd" or "rd" or "th")
        {
            _pos += 2;
            return Token.OrdinalNumber(value, new Span(start, _pos));
        }
        return Token.Number(value, new Span(start, _pos));
    }

    private Token LexTime(int start)
    {
        var colon = _pos;
        _pos++;
        AdvanceWhile(IsDigit);
        var text = _input[start.._pos];
        var hourDigits = colon - start;
        var minuteDigits = _pos - colon - 1;
        if (hourDigits is < 1 or > 2 || minuteDigits != 2)
        {
            throw Error($"time must be H:MM or HH:MM, got {text}", start);
        }
        var hour = NumberValue(start, colon)!.Value;
        var minute = NumberValue(colon + 1, _pos)!.Value;
        if (hour > 23 || minute > 59)
        {
            throw Error($"time must be 00:00-23:59, got {text}", start);
        }
        return Token.Time(hour, minute, new Span(start, _pos));
    }

    private HronException UnexpectedCharacter(int start)
    {
        var length = char.IsSurrogatePair(_input, start) ? 2 : 1;
        // A lone surrogate is reported by its own value, which ConvertToUtf32 would reject.
        int codePoint = length == 2 ? char.ConvertToUtf32(_input, start) : _input[start];
        // `'` is excluded because `'''` would not read as a quoted character.
        var shown = codePoint is >= '!' and <= '~' and not '\''
            ? $"'{(char)codePoint}'"
            : "U+" + codePoint.ToString("X4", CultureInfo.InvariantCulture);
        _pos = start + length;
        return Error($"unexpected character {shown}", start);
    }

    private bool IsIsoDateTail()
    {
        var rest = _input.AsSpan(_pos);
        return rest.Length >= 6 && rest[0] == '-' && IsDigit(rest[1]) && IsDigit(rest[2])
            && rest[3] == '-' && IsDigit(rest[4]) && IsDigit(rest[5]);
    }

    /// <summary>
    /// Checked at every digit, so a run of any length cannot overflow.
    /// </summary>
    private int? NumberValue(int start, int end)
    {
        long value = 0;
        for (var i = start; i < end; i++)
        {
            value = value * 10 + (_input[i] - '0');
            if (value > MaxNumber)
            {
                return null;
            }
        }
        return (int)value;
    }

    // Culture-aware lowering would map other letters onto ASCII ones (the Kelvin sign to k).
    private static string AsciiLower(string text)
        => string.Create(text.Length, text, (chars, source) =>
        {
            for (var i = 0; i < source.Length; i++)
            {
                chars[i] = source[i] is >= 'A' and <= 'Z' ? (char)(source[i] + ('a' - 'A')) : source[i];
            }
        });

    private static bool IsDigit(char c) => c is >= '0' and <= '9';
    private static bool IsAlpha(char c) => c is (>= 'a' and <= 'z') or (>= 'A' and <= 'Z');
    private static bool IsAlphanumeric(char c) => IsAlpha(c) || IsDigit(c);

    /// <summary>
    /// Only these four separate tokens; any other whitespace is an unexpected character.
    /// </summary>
    private static bool IsWhitespace(char c) => c is ' ' or '\t' or '\n' or '\r';

    private static readonly Span DummySpan = new(0, 0);

    private static readonly Dictionary<string, Token> KeywordMap = new(StringComparer.Ordinal)
    {
        ["every"] = Token.Keyword(TokenKind.Every, DummySpan),
        ["on"] = Token.Keyword(TokenKind.On, DummySpan),
        ["at"] = Token.Keyword(TokenKind.At, DummySpan),
        ["from"] = Token.Keyword(TokenKind.From, DummySpan),
        ["to"] = Token.Keyword(TokenKind.To, DummySpan),
        ["in"] = Token.Keyword(TokenKind.In, DummySpan),
        ["of"] = Token.Keyword(TokenKind.Of, DummySpan),
        ["the"] = Token.Keyword(TokenKind.The, DummySpan),
        ["last"] = Token.Keyword(TokenKind.Last, DummySpan),
        ["except"] = Token.Keyword(TokenKind.Except, DummySpan),
        ["until"] = Token.Keyword(TokenKind.Until, DummySpan),
        ["starting"] = Token.Keyword(TokenKind.Starting, DummySpan),
        ["during"] = Token.Keyword(TokenKind.During, DummySpan),
        ["year"] = Token.Keyword(TokenKind.Year, DummySpan),
        ["years"] = Token.Keyword(TokenKind.Year, DummySpan),
        ["day"] = Token.Keyword(TokenKind.Day, DummySpan),
        ["days"] = Token.Keyword(TokenKind.Day, DummySpan),
        ["weekday"] = Token.Keyword(TokenKind.Weekday, DummySpan),
        ["weekdays"] = Token.Keyword(TokenKind.Weekday, DummySpan),
        ["weekend"] = Token.Keyword(TokenKind.Weekend, DummySpan),
        ["weekends"] = Token.Keyword(TokenKind.Weekend, DummySpan),
        ["weeks"] = Token.Keyword(TokenKind.Weeks, DummySpan),
        ["week"] = Token.Keyword(TokenKind.Weeks, DummySpan),
        ["month"] = Token.Keyword(TokenKind.Month, DummySpan),
        ["months"] = Token.Keyword(TokenKind.Month, DummySpan),
        ["nearest"] = Token.Keyword(TokenKind.Nearest, DummySpan),
        ["next"] = Token.Keyword(TokenKind.Next, DummySpan),
        ["previous"] = Token.Keyword(TokenKind.Previous, DummySpan),

        ["monday"] = Token.DayName(Ast.Weekday.Monday, DummySpan),
        ["mon"] = Token.DayName(Ast.Weekday.Monday, DummySpan),
        ["tuesday"] = Token.DayName(Ast.Weekday.Tuesday, DummySpan),
        ["tue"] = Token.DayName(Ast.Weekday.Tuesday, DummySpan),
        ["wednesday"] = Token.DayName(Ast.Weekday.Wednesday, DummySpan),
        ["wed"] = Token.DayName(Ast.Weekday.Wednesday, DummySpan),
        ["thursday"] = Token.DayName(Ast.Weekday.Thursday, DummySpan),
        ["thu"] = Token.DayName(Ast.Weekday.Thursday, DummySpan),
        ["friday"] = Token.DayName(Ast.Weekday.Friday, DummySpan),
        ["fri"] = Token.DayName(Ast.Weekday.Friday, DummySpan),
        ["saturday"] = Token.DayName(Ast.Weekday.Saturday, DummySpan),
        ["sat"] = Token.DayName(Ast.Weekday.Saturday, DummySpan),
        ["sunday"] = Token.DayName(Ast.Weekday.Sunday, DummySpan),
        ["sun"] = Token.DayName(Ast.Weekday.Sunday, DummySpan),

        ["january"] = Token.MonthName(Ast.MonthName.January, DummySpan),
        ["jan"] = Token.MonthName(Ast.MonthName.January, DummySpan),
        ["february"] = Token.MonthName(Ast.MonthName.February, DummySpan),
        ["feb"] = Token.MonthName(Ast.MonthName.February, DummySpan),
        ["march"] = Token.MonthName(Ast.MonthName.March, DummySpan),
        ["mar"] = Token.MonthName(Ast.MonthName.March, DummySpan),
        ["april"] = Token.MonthName(Ast.MonthName.April, DummySpan),
        ["apr"] = Token.MonthName(Ast.MonthName.April, DummySpan),
        ["may"] = Token.MonthName(Ast.MonthName.May, DummySpan),
        ["june"] = Token.MonthName(Ast.MonthName.June, DummySpan),
        ["jun"] = Token.MonthName(Ast.MonthName.June, DummySpan),
        ["july"] = Token.MonthName(Ast.MonthName.July, DummySpan),
        ["jul"] = Token.MonthName(Ast.MonthName.July, DummySpan),
        ["august"] = Token.MonthName(Ast.MonthName.August, DummySpan),
        ["aug"] = Token.MonthName(Ast.MonthName.August, DummySpan),
        ["september"] = Token.MonthName(Ast.MonthName.September, DummySpan),
        ["sep"] = Token.MonthName(Ast.MonthName.September, DummySpan),
        ["october"] = Token.MonthName(Ast.MonthName.October, DummySpan),
        ["oct"] = Token.MonthName(Ast.MonthName.October, DummySpan),
        ["november"] = Token.MonthName(Ast.MonthName.November, DummySpan),
        ["nov"] = Token.MonthName(Ast.MonthName.November, DummySpan),
        ["december"] = Token.MonthName(Ast.MonthName.December, DummySpan),
        ["dec"] = Token.MonthName(Ast.MonthName.December, DummySpan),

        ["first"] = Token.Ordinal(OrdinalPosition.First, DummySpan),
        ["second"] = Token.Ordinal(OrdinalPosition.Second, DummySpan),
        ["third"] = Token.Ordinal(OrdinalPosition.Third, DummySpan),
        ["fourth"] = Token.Ordinal(OrdinalPosition.Fourth, DummySpan),
        ["fifth"] = Token.Ordinal(OrdinalPosition.Fifth, DummySpan),

        ["min"] = Token.IntervalUnit(Ast.IntervalUnit.Minutes, DummySpan),
        ["mins"] = Token.IntervalUnit(Ast.IntervalUnit.Minutes, DummySpan),
        ["minute"] = Token.IntervalUnit(Ast.IntervalUnit.Minutes, DummySpan),
        ["minutes"] = Token.IntervalUnit(Ast.IntervalUnit.Minutes, DummySpan),
        ["hour"] = Token.IntervalUnit(Ast.IntervalUnit.Hours, DummySpan),
        ["hours"] = Token.IntervalUnit(Ast.IntervalUnit.Hours, DummySpan),
        ["hr"] = Token.IntervalUnit(Ast.IntervalUnit.Hours, DummySpan),
        ["hrs"] = Token.IntervalUnit(Ast.IntervalUnit.Hours, DummySpan)
    };
}
