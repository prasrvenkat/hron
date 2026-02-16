using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace Hron.Tests;

public partial class ConformanceTest
{
    private static readonly JsonDocument Spec;
    private static readonly DateTimeOffset DefaultNow;

    static ConformanceTest()
    {
        var specPath = Path.Combine(AppContext.BaseDirectory, "tests.json");
        var json = File.ReadAllText(specPath);
        Spec = JsonDocument.Parse(json);
        DefaultNow = ParseZonedDateTime(Spec.RootElement.GetProperty("now").GetString()!);
    }

    // Parse tests

    public static TheoryData<string, string, string> GetParseTests()
    {
        var data = new TheoryData<string, string, string>();
        var parse = Spec.RootElement.GetProperty("parse");

        foreach (var section in parse.EnumerateObject())
        {
            if (section.Name == "description") continue;
            if (!section.Value.TryGetProperty("tests", out var tests)) continue;

            foreach (var tc in tests.EnumerateArray())
            {
                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var input = tc.GetProperty("input").GetString()!;
                var canonical = tc.GetProperty("canonical").GetString()!;
                data.Add(name, input, canonical);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetParseTests))]
    public void ParseTests(string _name, string input, string canonical)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(input);
        Assert.Equal(canonical, s.ToString());

        // Roundtrip test
        var s2 = Schedule.Parse(canonical);
        Assert.Equal(canonical, s2.ToString());
    }

    public static TheoryData<string, string> GetParseErrorTests()
    {
        var data = new TheoryData<string, string>();
        var tests = Spec.RootElement.GetProperty("parse_errors").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var input = tc.GetProperty("input").GetString()!;
            data.Add(name, input);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetParseErrorTests))]
    public void ParseErrorTests(string _name, string input)
    {
        _ = _name; // Used for test display
        Assert.Throws<HronException>(() => Schedule.Parse(input));
    }

    // Eval tests

    public static TheoryData<string, string, string?, string?> GetEvalNextTests()
    {
        var data = new TheoryData<string, string, string?, string?>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (section.Name == "description") continue;
            if (!section.Value.TryGetProperty("tests", out var tests)) continue;

            foreach (var tc in tests.EnumerateArray())
            {
                if (!tc.TryGetProperty("next", out var nextProp)) continue;

                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var expression = tc.GetProperty("expression").GetString()!;
                var now = tc.TryGetProperty("now", out var nowProp) ? nowProp.GetString() : null;
                var next = nextProp.ValueKind == JsonValueKind.Null ? null : nextProp.GetString();
                data.Add(name, expression, now, next);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalNextTests))]
    public void EvalNextTests(string _name, string expression, string? nowStr, string? expectedNext)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var result = s.NextFrom(now);

        if (expectedNext is null)
        {
            Assert.Null(result);
        }
        else
        {
            Assert.NotNull(result);
            var expected = ParseZonedDateTime(expectedNext);
            Assert.Equal(expected.ToUniversalTime(), result.Value.ToUniversalTime());
        }
    }

    public static TheoryData<string, string, string?, string> GetEvalNextDateTests()
    {
        var data = new TheoryData<string, string, string?, string>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (section.Name == "description") continue;
            if (!section.Value.TryGetProperty("tests", out var tests)) continue;

            foreach (var tc in tests.EnumerateArray())
            {
                if (!tc.TryGetProperty("next_date", out var nextDateProp)) continue;

                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var expression = tc.GetProperty("expression").GetString()!;
                var now = tc.TryGetProperty("now", out var nowProp) ? nowProp.GetString() : null;
                var nextDate = nextDateProp.GetString()!;
                data.Add(name, expression, now, nextDate);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalNextDateTests))]
    public void EvalNextDateTests(string _name, string expression, string? nowStr, string expectedDate)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var result = s.NextFrom(now);

        Assert.NotNull(result);
        var gotDate = result.Value.Date.ToString("yyyy-MM-dd");
        Assert.Equal(expectedDate, gotDate);
    }

    public static TheoryData<string, string, string?, int, string[]> GetEvalNextNTests()
    {
        var data = new TheoryData<string, string, string?, int, string[]>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (section.Name == "description") continue;
            if (!section.Value.TryGetProperty("tests", out var tests)) continue;

            foreach (var tc in tests.EnumerateArray())
            {
                if (!tc.TryGetProperty("next_n", out var nextNProp)) continue;

                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var expression = tc.GetProperty("expression").GetString()!;
                var now = tc.TryGetProperty("now", out var nowProp) ? nowProp.GetString() : null;
                var expectedStrs = nextNProp.EnumerateArray().Select(e => e.GetString()!).ToArray();
                var n = tc.TryGetProperty("next_n_count", out var countProp) ? countProp.GetInt32() : expectedStrs.Length;
                data.Add(name, expression, now, n, expectedStrs);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalNextNTests))]
    public void EvalNextNTests(string _name, string expression, string? nowStr, int n, string[] expectedStrs)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var results = s.NextNFrom(now, n);

        Assert.Equal(expectedStrs.Length, results.Count);

        for (var i = 0; i < expectedStrs.Length; i++)
        {
            var expected = ParseZonedDateTime(expectedStrs[i]);
            Assert.Equal(expected.ToUniversalTime(), results[i].ToUniversalTime());
        }
    }

    public static TheoryData<string, string, string?, int, int> GetEvalNextNLengthTests()
    {
        var data = new TheoryData<string, string, string?, int, int>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (section.Name == "description") continue;
            if (!section.Value.TryGetProperty("tests", out var tests)) continue;

            foreach (var tc in tests.EnumerateArray())
            {
                if (!tc.TryGetProperty("next_n_length", out var lengthProp)) continue;

                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var expression = tc.GetProperty("expression").GetString()!;
                var now = tc.TryGetProperty("now", out var nowProp) ? nowProp.GetString() : null;
                var n = tc.GetProperty("next_n_count").GetInt32();
                var expectedLength = lengthProp.GetInt32();
                data.Add(name, expression, now, n, expectedLength);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalNextNLengthTests))]
    public void EvalNextNLengthTests(string _name, string expression, string? nowStr, int n, int expectedLength)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var results = s.NextNFrom(now, n);

        Assert.Equal(expectedLength, results.Count);
    }

    // PreviousFrom tests

    public static TheoryData<string, string, string, string?> GetPreviousFromTests()
    {
        var data = new TheoryData<string, string, string, string?>();
        if (!Spec.RootElement.GetProperty("eval").TryGetProperty("previous_from", out var previousFromSection)) return data;
        if (!previousFromSection.TryGetProperty("tests", out var tests)) return data;

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.TryGetProperty("name", out var nameProp) ? nameProp.GetString()! : tc.GetProperty("expression").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            var now = tc.GetProperty("now").GetString()!;
            var expected = tc.GetProperty("expected").ValueKind == JsonValueKind.Null ? null : tc.GetProperty("expected").GetString();
            data.Add(name, expression, now, expected);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetPreviousFromTests))]
    public void PreviousFromTests(string _name, string expression, string nowStr, string? expectedStr)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var now = ParseZonedDateTime(nowStr);
        var result = s.PreviousFrom(now);

        if (expectedStr is null)
        {
            Assert.Null(result);
        }
        else
        {
            Assert.NotNull(result);
            var expected = ParseZonedDateTime(expectedStr);
            Assert.Equal(expected.ToUniversalTime(), result.Value.ToUniversalTime());
        }
    }

    // Matches tests

    public static TheoryData<string, string, string, bool> GetMatchesTests()
    {
        var data = new TheoryData<string, string, string, bool>();
        if (!Spec.RootElement.GetProperty("eval").TryGetProperty("matches", out var matchesSection)) return data;
        if (!matchesSection.TryGetProperty("tests", out var tests)) return data;

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            var datetime = tc.GetProperty("datetime").GetString()!;
            var expected = tc.GetProperty("expected").GetBoolean();
            data.Add(name, expression, datetime, expected);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetMatchesTests))]
    public void MatchesTests(string _name, string expression, string datetimeStr, bool expected)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var datetime = ParseZonedDateTime(datetimeStr);
        var result = s.Matches(datetime);

        Assert.Equal(expected, result);
    }

    // Occurrences tests

    public static TheoryData<string, string, string, int, string[]> GetOccurrencesTests()
    {
        var data = new TheoryData<string, string, string, int, string[]>();
        if (!Spec.RootElement.GetProperty("eval").TryGetProperty("occurrences", out var occurrencesSection)) return data;
        if (!occurrencesSection.TryGetProperty("tests", out var tests)) return data;

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            var from = tc.GetProperty("from").GetString()!;
            var take = tc.GetProperty("take").GetInt32();
            var expected = tc.GetProperty("expected").EnumerateArray().Select(e => e.GetString()!).ToArray();
            data.Add(name, expression, from, take, expected);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetOccurrencesTests))]
    public void OccurrencesTests(string _name, string expression, string fromStr, int take, string[] expectedStrs)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var from = ParseZonedDateTime(fromStr);
        var results = s.Occurrences(from).Take(take).ToList();

        Assert.Equal(expectedStrs.Length, results.Count);

        for (var i = 0; i < expectedStrs.Length; i++)
        {
            var expected = ParseZonedDateTime(expectedStrs[i]);
            Assert.Equal(expected.ToUniversalTime(), results[i].ToUniversalTime());
        }
    }

    // Between tests

    public static TheoryData<string, string, string, string, string[]?, int?> GetBetweenTests()
    {
        var data = new TheoryData<string, string, string, string, string[]?, int?>();
        if (!Spec.RootElement.GetProperty("eval").TryGetProperty("between", out var betweenSection)) return data;
        if (!betweenSection.TryGetProperty("tests", out var tests)) return data;

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            var from = tc.GetProperty("from").GetString()!;
            var to = tc.GetProperty("to").GetString()!;

            string[]? expected = null;
            int? expectedCount = null;

            if (tc.TryGetProperty("expected", out var expectedProp))
            {
                expected = expectedProp.EnumerateArray().Select(e => e.GetString()!).ToArray();
            }
            if (tc.TryGetProperty("expected_count", out var expectedCountProp))
            {
                expectedCount = expectedCountProp.GetInt32();
            }

            data.Add(name, expression, from, to, expected, expectedCount);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetBetweenTests))]
    public void BetweenTests(string _name, string expression, string fromStr, string toStr, string[]? expectedStrs, int? expectedCount)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(expression);
        var from = ParseZonedDateTime(fromStr);
        var to = ParseZonedDateTime(toStr);
        var results = s.Between(from, to).ToList();

        if (expectedStrs is not null)
        {
            Assert.Equal(expectedStrs.Length, results.Count);

            for (var i = 0; i < expectedStrs.Length; i++)
            {
                var expected = ParseZonedDateTime(expectedStrs[i]);
                Assert.Equal(expected.ToUniversalTime(), results[i].ToUniversalTime());
            }
        }
        else if (expectedCount.HasValue)
        {
            Assert.Equal(expectedCount.Value, results.Count);
        }
    }

    // Eval error tests

    public static TheoryData<string, string> GetEvalErrorTests()
    {
        var data = new TheoryData<string, string>();
        if (!Spec.RootElement.TryGetProperty("eval_errors", out var evalErrorsSection)) return data;
        if (!evalErrorsSection.TryGetProperty("tests", out var tests)) return data;

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            data.Add(name, expression);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalErrorTests))]
    public void EvalErrorTests(string _name, string expression)
    {
        _ = _name; // Used for test display
        // C# validates timezone at construction time (Schedule.Parse),
        // so these should fail at parse time.
        Assert.Throws<HronException>(() => Schedule.Parse(expression));
    }

    // Cron tests

    public static TheoryData<string, string, string> GetToCronTests()
    {
        var data = new TheoryData<string, string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("to_cron").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var hron = tc.GetProperty("hron").GetString()!;
            var cron = tc.GetProperty("cron").GetString()!;
            data.Add(name, hron, cron);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetToCronTests))]
    public void ToCronTests(string _name, string hron, string expectedCron)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(hron);
        var cron = s.ToCron();
        Assert.Equal(expectedCron, cron);
    }

    public static TheoryData<string, string> GetToCronErrorTests()
    {
        var data = new TheoryData<string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("to_cron_errors").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var hron = tc.GetProperty("hron").GetString()!;
            data.Add(name, hron);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetToCronErrorTests))]
    public void ToCronErrorTests(string _name, string hron)
    {
        _ = _name; // Used for test display
        var s = Schedule.Parse(hron);
        Assert.Throws<HronException>(() => s.ToCron());
    }

    public static TheoryData<string, string, string> GetFromCronTests()
    {
        var data = new TheoryData<string, string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("from_cron").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var cron = tc.GetProperty("cron").GetString()!;
            var hron = tc.GetProperty("hron").GetString()!;
            data.Add(name, cron, hron);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetFromCronTests))]
    public void FromCronTests(string _name, string cron, string expectedHron)
    {
        _ = _name; // Used for test display
        var s = Schedule.FromCron(cron);
        Assert.Equal(expectedHron, s.ToString());
    }

    public static TheoryData<string, string> GetFromCronErrorTests()
    {
        var data = new TheoryData<string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("from_cron_errors").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var cron = tc.GetProperty("cron").GetString()!;
            data.Add(name, cron);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetFromCronErrorTests))]
    public void FromCronErrorTests(string _name, string cron)
    {
        _ = _name; // Used for test display
        Assert.Throws<HronException>(() => Schedule.FromCron(cron));
    }

    public static TheoryData<string, string> GetCronRoundtripTests()
    {
        var data = new TheoryData<string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("roundtrip").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var hron = tc.GetProperty("hron").GetString()!;
            data.Add(name, hron);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetCronRoundtripTests))]
    public void CronRoundtripTests(string _name, string hron)
    {
        _ = _name; // Used for test display
        var s1 = Schedule.Parse(hron);
        var cron = s1.ToCron();

        var s2 = Schedule.FromCron(cron);
        var cron2 = s2.ToCron();

        Assert.Equal(cron, cron2);
    }

    // Helper: parse zoned datetime with timezone in brackets
    // Format: "2026-02-06T12:00:00+00:00[UTC]"
    [GeneratedRegex(@"^(.+?)\[([^\]]+)\]$")]
    private static partial Regex ZdtPattern();

    private static DateTimeOffset ParseZonedDateTime(string s)
    {
        var match = ZdtPattern().Match(s);
        if (!match.Success)
        {
            // Try parsing without brackets
            return DateTimeOffset.Parse(s);
        }

        var isoStr = match.Groups[1].Value;
        var tzName = match.Groups[2].Value;

        var parsed = DateTimeOffset.Parse(isoStr);
        var tz = TimeZoneInfo.FindSystemTimeZoneById(tzName);
        return TimeZoneInfo.ConvertTime(parsed, tz);
    }
}
