using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace Hron.Tests;

public class ErrorFuzzTest
{
    private const int Inputs = 6000;
    private const ulong Seed = 0x5EED_C5A2;

    private const string What =
        @"'every' or 'on'"
        + @"|'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number"
        + @"|a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)"
        + @"|'at'|a time \(HH:MM\)|'from'|'to'"
        + @"|'day', 'weekday', 'weekend' or a day name"
        + @"|'on'|a day name|'the'"
        + @"|a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'"
        + @"|'day', 'weekday' or a day name"
        + @"|'nearest'|'weekday'|a day such as 15th"
        + @"|a month name or 'the'"
        + @"|a day such as 15th, 'last' or an ordinal such as 'first'"
        + @"|'weekday' or a day name"
        + @"|'of'|a month name|a day number"
        + @"|a date \(YYYY-MM-DD, or a month and day\)|a date \(YYYY-MM-DD\)|a timezone";
    private const string Month = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec";
    // .NET's case-insensitive matching is not ASCII-only, so the suffix spells out its cases.
    private const string Day = "[0-9]+(?:[sS][tT]|[nN][dD]|[rR][dD]|[tT][hH])?";
    private const string Time = "[0-9]{1,2}:[0-9]{2}";

    private static readonly string[] ClauseOrder = ["except", "until", "starting", "during", "in"];
    private static readonly char[] TokenSeparators = [' ', '\t', '\r', '\n'];

    private sealed record Failure(string Input, Span Span, string Spanned);

    private sealed record Template(string Kind, Regex Pattern, Func<Match, Failure, string?> Check);

    private static string? Ensure(bool holds, Func<string> problem) => holds ? null : problem();

    /// <summary>Saturates, since a digit run can be thousands of digits long.</summary>
    private static ulong Value(string text)
    {
        ulong n = 0;
        foreach (var c in text.TakeWhile(c => c is >= '0' and <= '9'))
        {
            n = n > (ulong.MaxValue - 9) / 10 ? ulong.MaxValue : n * 10 + (ulong)(c - '0');
        }
        return n;
    }

    private static string AsciiLower(string text)
        => new(text.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + ('a' - 'A')) : c).ToArray());

    private static string AsciiUpper(string text)
        => new(text.Select(c => c is >= 'a' and <= 'z' ? (char)(c - ('a' - 'A')) : c).ToArray());

    // spec/README.md, "Error Structure": a lone surrogate counts as one code point, as a pair does.
    private static List<string> CodePoints(string text)
    {
        var points = new List<string>();
        for (var i = 0; i < text.Length; i++)
        {
            var length = char.IsSurrogatePair(text, i) ? 2 : 1;
            points.Add(text.Substring(i, length));
            i += length - 1;
        }
        return points;
    }

    private static Template Lex(string pattern, Func<Match, Failure, string?> check) => new("lex", new Regex(pattern), check);

    private static Template Parse(string pattern, Func<Match, Failure, string?> check) => new("parse", new Regex(pattern), check);

    private static string? NoCheck(Match _, Failure __) => null;

    /// <summary>
    /// From spec/README.md, "Lex errors" and "Parse errors". A <c>span</c> group must equal the
    /// spanned text; every other group is read by its template's check.
    /// </summary>
    private static readonly Template[] Templates =
    [
        Lex(@"^unexpected character '(?<span>[!-&(-~])'\z", (_, f) =>
        {
            var c = f.Spanned[0];
            return Ensure(!char.IsAsciiLetterOrDigit(c) && c != ',', () => $"'{c}' starts a token, so it is never unexpected");
        }),
        Lex(@"^unexpected character U\+(?<code>[0-9A-F]{4,})\z", (m, f) =>
        {
            var shown = Convert.ToInt32(m.Groups["code"].Value, 16);
            var quotable = shown is >= 0x21 and <= 0x7e and not 0x27;
            var points = CodePoints(f.Spanned);
            var described = points.Count == 1
                && (points[0].Length == 2 ? char.ConvertToUtf32(points[0], 0) : points[0][0]) == shown;
            return Ensure(described && !quotable, () => $"U+{m.Groups["code"].Value} does not describe '{f.Spanned}'");
        }),
        Lex(@"^unknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'\z", NoCheck),
        Lex(@"^time must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))\z", (m, _) =>
        {
            var (hour, minute) = (m.Groups["hour"].Value, m.Groups["minute"].Value);
            return Ensure(hour.Length is < 1 or > 2 || minute.Length != 2, () => $"{hour}:{minute} is H:MM or HH:MM");
        }),
        Lex(@"^time must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))\z", (m, _) =>
        {
            var (hour, minute) = (Value(m.Groups["hour"].Value), Value(m.Groups["minute"].Value));
            return Ensure(hour > 23 || minute > 59, () => $"{hour}:{minute} is in range");
        }),
        Lex(@"^number must be at most 2147483647\z", (_, f) =>
        {
            var digits = f.Spanned.Length > 0 && f.Spanned.All(c => c is >= '0' and <= '9');
            return Ensure(digits && Value(f.Spanned) > 2147483647, () => $"'{f.Spanned}' is not digits above 2147483647");
        }),
        Parse(@"^empty expression\z", (_, f) =>
        {
            var blank = f.Input.Trim(TokenSeparators).Length == 0;
            return Ensure(blank && f.Span == new Span(0, 0), () => $"empty expression with span {f.Span} for '{f.Input}'");
        }),
        Parse($@"^expected (?:{What}), got (?:'(?<span>.+)'|(?<end>end of input))\z", (m, f) =>
        {
            if (!m.Groups["end"].Success)
            {
                return null;
            }
            var end = CodePoints(f.Input.TrimEnd(TokenSeparators)).Count;
            return Ensure(f.Span == new Span(end, end), () => $"end of input at {f.Span}, expected {end}..{end}");
        }),
        Parse(@"^interval must be 1-2147483647, got (?<span>[0-9]+)\z", (_, f) =>
            Ensure(Value(f.Spanned) == 0, () => $"interval {f.Spanned} is valid")),
        Parse($@"^day must be 1-31, got (?<span>{Day})\z", (_, f) =>
        {
            var day = Value(f.Spanned);
            return Ensure(day is 0 or > 31, () => $"day {day} is within 1-31");
        }),
        Parse($@"^day must be 1-(?<max>[0-9]+) for (?<month>{Month}), got (?<span>{Day})\z", (m, f) =>
        {
            var month = m.Groups["month"].Value;
            ulong length = month switch
            {
                "feb" => 29,
                "apr" or "jun" or "sep" or "nov" => 30,
                _ => 31,
            };
            var (max, day) = (Value(m.Groups["max"].Value), Value(f.Spanned));
            return Ensure(max == length && day > max && day <= 31, () => $"day {day} against 1-{max} for {month}");
        }),
        Parse($@"^day range must not run backwards: (?<a>{Day}) to (?<b>{Day})\z", (m, f) =>
        {
            var (a, b) = (m.Groups["a"].Value, m.Groups["b"].Value);
            var spansBoth = f.Spanned.StartsWith(a, StringComparison.Ordinal) && f.Spanned.EndsWith(b, StringComparison.Ordinal);
            return Ensure(spansBoth && Value(a) > Value(b), () => $"{a} to {b} against the span '{f.Spanned}'");
        }),
        Parse($@"^time window must not run backwards: (?<from>{Time}) to (?<to>{Time}) \(a window cannot cross midnight\)\z", (m, f) =>
        {
            var (from, to) = (m.Groups["from"].Value, m.Groups["to"].Value);
            static ulong Minutes(string t) => Value(t[..t.IndexOf(':')]) * 60 + Value(t[(t.IndexOf(':') + 1)..]);
            var spansBoth = f.Spanned.StartsWith(from, StringComparison.Ordinal) && f.Spanned.EndsWith(to, StringComparison.Ordinal);
            return Ensure(spansBoth && Minutes(from) > Minutes(to), () => $"{from} to {to} against the span '{f.Spanned}'");
        }),
        Parse(@"^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?<span>(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2}))\z", (m, f) =>
        {
            var (year, month, day) = ((int)Value(m.Groups["y"].Value), (int)Value(m.Groups["m"].Value), (int)Value(m.Groups["d"].Value));
            var calendar = year >= 1 && month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month);
            return Ensure(!calendar, () => $"{f.Spanned} is a calendar date");
        }),
        Parse(@"^timezone must be UTC or an Area/Location name such as America/New_York, got (?<span>.+)\z", NoCheck),
        Parse(@"^duplicate '(?<keyword>except|until|starting|during|in)' clause\z", (m, f) =>
        {
            var keyword = m.Groups["keyword"].Value;
            return Ensure(keyword == AsciiLower(f.Spanned), () => $"duplicate '{keyword}' but the span holds '{f.Spanned}'");
        }),
        Parse(@"^'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'\z", (m, f) =>
        {
            var (keyword, last) = (m.Groups["keyword"].Value, m.Groups["last"].Value);
            var (k, l) = (Array.IndexOf(ClauseOrder, keyword), Array.IndexOf(ClauseOrder, last));
            var earlier = k >= 0 && l >= 0 && k < l;
            return Ensure(earlier && keyword == AsciiLower(f.Spanned), () => $"'{keyword}' before '{last}' with the span '{f.Spanned}'");
        }),
        Parse(@"^unexpected '(?<span>.+)' after the schedule\z", NoCheck),
        Parse($@"^until (?<month>{Month}) (?<day>[1-9][0-9]?) has no year: add a starting date, or use an ISO date\z", (m, f) =>
        {
            var (month, day) = (m.Groups["month"].Value, m.Groups["day"].Value);
            var words = f.Spanned.Split(TokenSeparators, StringSplitOptions.RemoveEmptyEntries);
            var endsAtDay = f.Spanned.Length > 0 && !TokenSeparators.Contains(f.Spanned[^1]);
            var matchesMessage = endsAtDay && words.Length == 3
                && AsciiLower(words[0]) == "until"
                && AsciiLower(words[1]).StartsWith(month, StringComparison.Ordinal)
                && words[2][0] is >= '0' and <= '9'
                && Value(words[2]).ToString(System.Globalization.CultureInfo.InvariantCulture) == day;
            return Ensure(matchesMessage, () => $"the span '{f.Spanned}' is not 'until {month} {day}'");
        }),
    ];

    private static readonly string[] Fragments =
    [
        "every", "on", "at", "from", "to", "in", "IN", "of", "the", "last", "except", "until", "starting",
        "during", "nearest", "next", "previous", "day", "Days", "weekdays", "weekend", "week", "month",
        "years", "min", "hrs", "monday", "FRI", "jan", "february", "first", "fifth",
        "0", "1", "00", "15th", "31ST", "2nd", "2147483647", "2147483648", "99999999999999999999",
        "09:00", "9:5", "24:00", "9:", "17:30", "2026-02-28", "2026-02-30", "0000-01-01", "12026-03-15",
        ",", ":", "-", "/", "'", "\"", "#", "~", "_",
        "UTC", "America/New_York", "Nope/Zone", "Europe/\u0130stanbul",
        "\u00e9", "e\u0301", "\u212a", "\u00a0", "\u2028", "\ufeff", "\uff10", "\U0001F600", "\U0010FFFF",
        "\U0001D7D8", "\0", "\u000b", "\u000c", "\u007f", "\u001b",
        // C# strings can hold lone surrogates, which must each be one code point.
        "\uD800", "\uDFFF",
    ];

    private static readonly string[] Separators = ["", " ", " ", " ", "  ", "\t", "\r\n", "\n"];

    private static readonly string[] Clauses =
    [
        "except dec 25", "except 2026-12-25, jan 1", "until 2027-12-31", "until dec 31",
        "starting 2026-01-01", "during jan, jul", "in UTC", "IN America/New_York",
    ];

    /// <summary>SplitMix64: a fixed seed gives the same inputs on every platform.</summary>
    private sealed class Rng(ulong state)
    {
        private ulong _state = state;

        private ulong Next()
        {
            _state += 0x9E37_79B9_7F4A_7C15;
            var z = _state;
            z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9;
            z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB;
            return z ^ (z >> 31);
        }

        public int Below(int n) => (int)(Next() % (ulong)n);

        public string Pick(string[] items) => items[Below(items.Length)];
    }

    private static List<string> Corpus()
    {
        using var spec = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "tests.json")));
        var parseInputs = spec.RootElement.GetProperty("parse").EnumerateObject()
            .Where(section => section.Value.ValueKind == JsonValueKind.Object && section.Value.TryGetProperty("tests", out _))
            .SelectMany(section => section.Value.GetProperty("tests").EnumerateArray());
        var errorInputs = spec.RootElement.GetProperty("parse_errors").GetProperty("tests").EnumerateArray();
        return parseInputs.Concat(errorInputs).Select(c => c.GetProperty("input").GetString()!).ToList();
    }

    private static string RandomText(Rng rng)
    {
        var count = rng.Below(12) + 1;
        var parts = new List<string>();
        for (var i = 0; i < count; i++)
        {
            parts.Add(rng.Pick(Separators));
            parts.Add(rng.Pick(Fragments));
        }
        return string.Concat(parts);
    }

    private static string Mutate(Rng rng, string input)
    {
        var words = input.Split(' ').ToList();
        var i = rng.Below(words.Count);
        switch (rng.Below(7))
        {
            case 0:
                words.RemoveAt(i);
                break;
            case 1:
                var j = rng.Below(words.Count);
                (words[i], words[j]) = (words[j], words[i]);
                break;
            case 2:
                words.Insert(rng.Below(words.Count + 1), words[i]);
                break;
            case 3:
                var points = CodePoints(input);
                return string.Concat(points.Take(rng.Below(points.Count + 1)));
            case 4:
                words[i] = AsciiUpper(words[i]);
                break;
            case 5:
                words[i] = rng.Pick(Fragments);
                break;
            default:
                var fragment = rng.Pick(Fragments);
                var wordPoints = CodePoints(words[i]);
                wordPoints.Insert(rng.Below(wordPoints.Count + 1), fragment);
                words[i] = string.Concat(wordPoints);
                break;
        }
        return string.Join(' ', words);
    }

    private static string WithClauses(Rng rng, string input)
    {
        var count = rng.Below(4) + 1;
        for (var i = 0; i < count; i++)
        {
            input += " " + rng.Pick(Clauses);
        }
        return input;
    }

    private static string Generate(Rng rng, List<string> corpus)
    {
        switch (rng.Below(4))
        {
            case 0:
                return RandomText(rng);
            case 1:
                return WithClauses(rng, corpus[rng.Below(corpus.Count)]);
            default:
                var input = corpus[rng.Below(corpus.Count)];
                var mutations = rng.Below(4);
                for (var i = 0; i < mutations; i++)
                {
                    input = Mutate(rng, input);
                }
                return input;
        }
    }

    private static (int Index, string? Problem) Check(string input, HronException error)
    {
        if (error.Kind is not (ErrorKind.Lex or ErrorKind.Parse) || error.Span is not { } span)
        {
            return (-1, $"neither lex nor parse with a span: {error.Kind}");
        }
        var kind = error.Kind.ToValue();
        var message = error.Message;
        var problem = Ensure(!Schedule.Validate(input), () => "validate is true")
            ?? Ensure(error.Input == input, () => $"error input is '{error.Input}'");
        var points = CodePoints(input);
        problem ??= Ensure(span.Start >= 0 && span.Start <= span.End && span.End <= points.Count, () => $"span {span} outside 0..={points.Count}");
        if (problem is not null)
        {
            return (-1, problem);
        }
        var failure = new Failure(input, span, string.Concat(points.Skip(span.Start).Take(span.End - span.Start)));

        var index = Array.FindIndex(Templates, t => t.Kind == kind && t.Pattern.IsMatch(message));
        if (index < 0)
        {
            return (-1, $"{kind} message '{message}' matches no template");
        }
        var match = Templates[index].Pattern.Match(message);
        var echoed = match.Groups["span"];
        problem = Ensure(!echoed.Success || echoed.Value == failure.Spanned,
                () => $"message echoes '{echoed.Value}' but the span holds '{failure.Spanned}'")
            ?? Templates[index].Check(match, failure);

        var expectedSuggestion = message.StartsWith("until ", StringComparison.Ordinal)
            ? $"until {match.Groups["month"].Value} {match.Groups["day"].Value} starting YYYY-MM-DD"
            : null;
        problem ??= Ensure(error.Suggestion == expectedSuggestion,
            () => $"suggestion '{error.Suggestion}', expected '{expectedSuggestion}'");

        var rich = error.DisplayRich();
        problem ??= Ensure(rich.Split('\n').Length == 3 && rich.StartsWith($"error: {message}\n", StringComparison.Ordinal),
            () => $"DisplayRich is not three lines: '{rich}'");
        return (index, problem);
    }

    [Fact]
    public void GeneratedInputsFailOnlyWithSpecErrors()
    {
        var corpus = Corpus();
        var rng = new Rng(Seed);
        var hits = new int[Templates.Length];
        var parsed = 0;
        var failures = new List<string>();

        for (var n = 0; n < Inputs; n++)
        {
            var input = Generate(rng, corpus);
            try
            {
                Schedule.Parse(input);
                parsed++;
            }
            catch (HronException error)
            {
                var (index, problem) = Check(input, error);
                if (problem is not null)
                {
                    failures.Add($"'{input}': {problem}");
                }
                else
                {
                    hits[index]++;
                }
            }
            catch (Exception e)
            {
                failures.Add($"'{input}': parse threw {e.GetType().Name}: {e.Message}");
            }
        }

        Assert.True(failures.Count == 0, $"{failures.Count} failures, first ones:\n{string.Join("\n", failures.Take(20))}");
        Assert.True(parsed > Inputs / 20, $"only {parsed} inputs parsed; the generator has drifted");
        var unused = Templates.Where((_, i) => hits[i] == 0).Select(t => t.Pattern.ToString()).ToList();
        Assert.True(unused.Count == 0, $"templates no input produced:\n{string.Join("\n", unused)}");
    }
}
