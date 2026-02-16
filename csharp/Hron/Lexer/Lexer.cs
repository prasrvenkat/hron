using Hron.Ast;

namespace Hron.Lexer;

/// <summary>
/// Tokenizes input strings into a list of tokens.
/// </summary>
public sealed class Lexer
{
    private readonly string _input;
    private int _pos;
    private bool _afterIn;

    private Lexer(string input)
    {
        _input = input;
        _pos = 0;
        _afterIn = false;
    }

    /// <summary>
    /// Tokenizes the input string into a list of tokens.
    /// </summary>
    public static List<Token> Tokenize(string input)
        => new Lexer(input).DoTokenize();

    private List<Token> DoTokenize()
    {
        var tokens = new List<Token>();
        while (true)
        {
            SkipWhitespace();
            if (_pos >= _input.Length)
            {
                break;
            }

            if (_afterIn)
            {
                _afterIn = false;
                tokens.Add(LexTimezone());
                continue;
            }

            var start = _pos;
            var ch = _input[_pos];

            if (ch == ',')
            {
                _pos++;
                tokens.Add(Token.Comma(new Span(start, _pos)));
                continue;
            }

            if (IsDigit(ch))
            {
                tokens.Add(LexNumberOrTimeOrDate());
                continue;
            }

            if (IsAlpha(ch))
            {
                tokens.Add(LexWord());
                continue;
            }

            throw HronException.Lex($"unexpected character '{ch}'", new Span(start, start + 1), _input);
        }

        return tokens;
    }

    private void SkipWhitespace()
    {
        while (_pos < _input.Length && IsWhitespace(_input[_pos]))
        {
            _pos++;
        }
    }

    private Token LexTimezone()
    {
        SkipWhitespace();
        var start = _pos;
        while (_pos < _input.Length && !IsWhitespace(_input[_pos]))
        {
            _pos++;
        }
        var tz = _input[start.._pos];
        if (tz.Length == 0)
        {
            throw HronException.Lex("expected timezone after 'in'", new Span(start, start + 1), _input);
        }
        return Token.Timezone(tz, new Span(start, _pos));
    }

    private Token LexNumberOrTimeOrDate()
    {
        var start = _pos;

        // Read digits
        var numStart = _pos;
        while (_pos < _input.Length && IsDigit(_input[_pos]))
        {
            _pos++;
        }
        var digits = _input[numStart.._pos];

        // Check for ISO date: YYYY-MM-DD
        if (digits.Length == 4 && _pos < _input.Length && _input[_pos] == '-')
        {
            var remaining = _input[start..];
            if (remaining.Length >= 10
                && remaining[4] == '-'
                && IsDigit(remaining[5])
                && IsDigit(remaining[6])
                && remaining[7] == '-'
                && IsDigit(remaining[8])
                && IsDigit(remaining[9]))
            {
                _pos = start + 10;
                return Token.IsoDate(_input[start.._pos], new Span(start, _pos));
            }
        }

        // Check for time: HH:MM or H:MM
        if ((digits.Length == 1 || digits.Length == 2)
            && _pos < _input.Length
            && _input[_pos] == ':')
        {
            _pos++; // skip ':'
            var minStart = _pos;
            while (_pos < _input.Length && IsDigit(_input[_pos]))
            {
                _pos++;
            }
            var minDigits = _input[minStart.._pos];
            if (minDigits.Length == 2)
            {
                var hour = int.Parse(digits);
                var minute = int.Parse(minDigits);
                if (hour > 23 || minute > 59)
                {
                    throw HronException.Lex("invalid time", new Span(start, _pos), _input);
                }
                return Token.Time(hour, minute, new Span(start, _pos));
            }
        }

        var num = int.Parse(digits);

        // Check for ordinal suffix: st, nd, rd, th
        if (_pos + 1 < _input.Length)
        {
            var suffix = _input[_pos..(_pos + 2)].ToLowerInvariant();
            if (suffix is "st" or "nd" or "rd" or "th")
            {
                _pos += 2;
                return Token.OrdinalNumber(num, new Span(start, _pos));
            }
        }

        return Token.Number(num, new Span(start, _pos));
    }

    private Token LexWord()
    {
        var start = _pos;
        while (_pos < _input.Length && (IsAlphanumeric(_input[_pos]) || _input[_pos] == '_'))
        {
            _pos++;
        }
        var word = _input[start.._pos].ToLowerInvariant();
        var span = new Span(start, _pos);

        if (!KeywordMap.TryGetValue(word, out var template))
        {
            throw HronException.Lex($"unknown keyword '{word}'", span, _input);
        }

        // Create a new token with the actual span
        var result = template.Kind switch
        {
            TokenKind.DayName => Token.DayName(template.DayNameVal!.Value, span),
            TokenKind.MonthName => Token.MonthName(template.MonthNameVal!.Value, span),
            TokenKind.Ordinal => Token.Ordinal(template.OrdinalVal!.Value, span),
            TokenKind.IntervalUnit => Token.IntervalUnit(template.UnitVal!.Value, span),
            _ => Token.Keyword(template.Kind, span)
        };

        if (template.Kind == TokenKind.In)
        {
            _afterIn = true;
        }

        return result;
    }

    private static bool IsDigit(char c) => c is >= '0' and <= '9';
    private static bool IsAlpha(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    private static bool IsAlphanumeric(char c) => IsAlpha(c) || IsDigit(c);
    private static bool IsWhitespace(char c) => c is ' ' or '\t' or '\n' or '\r';

    private static readonly Span DummySpan = new(0, 0);

    private static readonly Dictionary<string, Token> KeywordMap = new(StringComparer.OrdinalIgnoreCase)
    {
        // Keywords
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

        // Day names
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

        // Month names
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

        // Ordinals
        ["first"] = Token.Ordinal(OrdinalPosition.First, DummySpan),
        ["second"] = Token.Ordinal(OrdinalPosition.Second, DummySpan),
        ["third"] = Token.Ordinal(OrdinalPosition.Third, DummySpan),
        ["fourth"] = Token.Ordinal(OrdinalPosition.Fourth, DummySpan),
        ["fifth"] = Token.Ordinal(OrdinalPosition.Fifth, DummySpan),

        // Interval units
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
