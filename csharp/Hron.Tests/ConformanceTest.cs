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

        var s2 = Schedule.Parse(canonical);
        Assert.Equal(canonical, s2.ToString());
    }

    private static JsonElement ParseErrorCases => Spec.RootElement.GetProperty("parse_errors").GetProperty("tests");

    public static TheoryData<string, int> GetParseErrorTests()
    {
        var data = new TheoryData<string, int>();
        var index = 0;
        foreach (var tc in ParseErrorCases.EnumerateArray())
        {
            data.Add(tc.GetProperty("name").GetString()!, index++);
        }
        return data;
    }

    private static readonly string[] ErrorFields = ["kind", "message", "span", "suggestion"];

    [Theory]
    [MemberData(nameof(GetParseErrorTests))]
    public void ParseErrorTests(string _name, int index)
    {
        _ = _name;
        var tc = ParseErrorCases[index];
        var input = tc.GetProperty("input").GetString()!;
        var expected = tc.GetProperty("error");
        var unknown = expected.EnumerateObject().Select(f => f.Name).Except(ErrorFields).ToList();
        Assert.True(unknown.Count == 0, $"error fields this runner does not know: {string.Join(", ", unknown)}");

        Assert.False(Schedule.Validate(input), $"Validate(\"{input}\") is true");
        var error = Assert.Throws<HronException>(() => Schedule.Parse(input));
        Assert.Equal(expected.GetProperty("kind").GetString(), error.Kind.ToValue());
        Assert.Equal(expected.GetProperty("message").GetString(), error.Message);
        var span = expected.GetProperty("span").EnumerateArray().Select(e => e.GetInt32()).ToArray();
        Assert.Equal(2, span.Length);
        Assert.Equal(new Span(span[0], span[1]), error.Span);
        var suggestion = expected.TryGetProperty("suggestion", out var s) ? s.GetString() : null;
        Assert.Equal(suggestion, error.Suggestion);
        if (tc.TryGetProperty("display", out var display))
        {
            Assert.Equal(display.GetString(), error.DisplayRich());
        }
    }

    public static TheoryData<string, string, string?, string?> GetEvalNextTests()
    {
        var data = new TheoryData<string, string, string?, string?>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (!IsNextStyleSection(section)) continue;

            foreach (var tc in section.Value.GetProperty("tests").EnumerateArray())
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
        _ = _name;
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

    public static TheoryData<string, string, string?, string?> GetEvalNextDateTests()
    {
        var data = new TheoryData<string, string, string?, string?>();
        var eval = Spec.RootElement.GetProperty("eval");

        foreach (var section in eval.EnumerateObject())
        {
            if (!IsNextStyleSection(section)) continue;

            foreach (var tc in section.Value.GetProperty("tests").EnumerateArray())
            {
                if (!tc.TryGetProperty("next_date", out var nextDateProp)) continue;

                var name = $"{section.Name}/{tc.GetProperty("name").GetString()}";
                var expression = tc.GetProperty("expression").GetString()!;
                var now = tc.TryGetProperty("now", out var nowProp) ? nowProp.GetString() : null;
                var nextDate = nextDateProp.GetString();
                data.Add(name, expression, now, nextDate);
            }
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetEvalNextDateTests))]
    public void EvalNextDateTests(string _name, string expression, string? nowStr, string? expectedDate)
    {
        _ = _name;
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var result = s.NextFrom(now);

        if (expectedDate is null)
        {
            Assert.Null(result);
            return;
        }
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
            if (!IsNextStyleSection(section)) continue;

            foreach (var tc in section.Value.GetProperty("tests").EnumerateArray())
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
        _ = _name;
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
            if (!IsNextStyleSection(section)) continue;

            foreach (var tc in section.Value.GetProperty("tests").EnumerateArray())
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
        _ = _name;
        var s = Schedule.Parse(expression);
        var now = nowStr is not null ? ParseZonedDateTime(nowStr) : DefaultNow;
        var results = s.NextNFrom(now, n);

        Assert.Equal(expectedLength, results.Count);
    }

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
        _ = _name;
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
        _ = _name;
        var s = Schedule.Parse(expression);
        var datetime = ParseZonedDateTime(datetimeStr);
        var result = s.Matches(datetime);

        Assert.Equal(expected, result);
    }

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
        _ = _name;
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
        _ = _name;
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
        else
        {
            Assert.Fail("between case has neither expected nor expected_count");
        }
    }

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
        _ = _name;
        var s = Schedule.Parse(hron);
        var cron = s.ToCron();
        Assert.Equal(expectedCron, cron);
    }

    public static TheoryData<string, string, string> GetToCronErrorTests()
    {
        var data = new TheoryData<string, string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("to_cron_errors").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var hron = tc.GetProperty("hron").GetString()!;
            var error = tc.GetProperty("error").GetString()!;
            data.Add(name, hron, error);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetToCronErrorTests))]
    public void ToCronErrorTests(string _name, string hron, string expectedError)
    {
        _ = _name;
        var s = Schedule.Parse(hron);
        var e = Assert.Throws<HronException>(() => s.ToCron());
        Assert.Equal(ErrorKind.Cron, e.Kind);
        Assert.Equal(expectedError, e.Message);
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
        _ = _name;
        var s = Schedule.FromCron(cron);
        Assert.Equal(expectedHron, s.ToString());
    }

    public static TheoryData<string, string, string> GetFromCronErrorTests()
    {
        var data = new TheoryData<string, string, string>();
        var tests = Spec.RootElement.GetProperty("cron").GetProperty("from_cron_errors").GetProperty("tests");

        foreach (var tc in tests.EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var cron = tc.GetProperty("cron").GetString()!;
            var error = tc.GetProperty("error").GetString()!;
            data.Add(name, cron, error);
        }

        return data;
    }

    [Theory]
    [MemberData(nameof(GetFromCronErrorTests))]
    public void FromCronErrorTests(string _name, string cron, string expectedError)
    {
        _ = _name;
        var e = Assert.Throws<HronException>(() => Schedule.FromCron(cron));
        Assert.Equal(ErrorKind.Cron, e.Kind);
        Assert.Equal(expectedError, e.Message);
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
        _ = _name;
        var s1 = Schedule.Parse(hron);
        var cron = s1.ToCron();

        var s2 = Schedule.FromCron(cron);
        var cron2 = s2.ToCron();

        Assert.Equal(cron, cron2);
    }

    private static readonly string[] KnownTopLevel =
        ["$schema", "version", "description", "now", "_eval_assertion_types", "_behavioral_notes",
         "parse", "parse_errors", "eval", "cron", "invariants"];

    private sealed record CaseShape(string[] Fields, Func<JsonElement, bool> HasAssertion);

    private static readonly CaseShape ParseShape = new(["input", "canonical"], tc => Has(tc, "input", "canonical"));

    private static readonly CaseShape NextShape = new(
        ["expression", "now", "next", "next_date", "next_n", "next_n_count", "next_n_length"],
        tc => Has(tc, "expression") && (Has(tc, "next") || Has(tc, "next_date") || Has(tc, "next_n") || Has(tc, "next_n_length")));

    // The fields this runner checks per section, as the spec's "Writing a runner" lists them;
    // parse.* sections use ParseShape and eval sections not named here use NextShape.
    private static readonly Dictionary<string, CaseShape> CaseShapes = new()
    {
        ["parse_errors"] = new(["input", "error", "display"], tc => Has(tc, "input", "error")),
        ["cron/to_cron"] = new(["hron", "cron"], tc => Has(tc, "hron", "cron")),
        ["cron/to_cron_errors"] = new(["hron", "error"], tc => Has(tc, "hron", "error")),
        ["cron/from_cron"] = new(["cron", "hron"], tc => Has(tc, "cron", "hron")),
        ["cron/from_cron_errors"] = new(["cron", "error"], tc => Has(tc, "cron", "error")),
        ["cron/roundtrip"] = new(["hron"], tc => Has(tc, "hron")),
        ["eval/matches"] = new(["expression", "datetime", "expected"], tc => Has(tc, "expression", "datetime", "expected")),
        ["eval/previous_from"] = new(["expression", "now", "expected"], tc => Has(tc, "expression", "now", "expected")),
        ["eval/occurrences"] = new(["expression", "from", "take", "expected"], tc => Has(tc, "expression", "from", "take", "expected")),
        ["eval/between"] = new(
            ["expression", "from", "to", "expected", "expected_count"],
            tc => Has(tc, "expression", "from", "to") && (Has(tc, "expected") || Has(tc, "expected_count"))),
        ["invariants"] = new(["expression", "now"], tc => Has(tc, "expression", "now")),
    };

    private static readonly string[] Labels = ["name", "description"];

    private static bool Has(JsonElement tc, params string[] fields) => fields.All(f => tc.TryGetProperty(f, out _));

    private static bool IsNextStyleSection(JsonProperty section) =>
        section.Name != "description" && !CaseShapes.ContainsKey($"eval/{section.Name}");

    private static IEnumerable<(string Path, JsonElement Section)> CaseSections()
    {
        foreach (var top in new[] { "parse", "eval", "cron" })
        {
            foreach (var section in Spec.RootElement.GetProperty(top).EnumerateObject().Where(p => p.Name != "description"))
            {
                yield return ($"{top}/{section.Name}", section.Value);
            }
        }
        foreach (var top in new[] { "parse_errors", "invariants" })
        {
            yield return (top, Spec.RootElement.GetProperty(top));
        }
    }

    private static CaseShape? ShapeOf(string path) =>
        CaseShapes.TryGetValue(path, out var shape) ? shape
        : path.StartsWith("parse/") ? ParseShape
        : path.StartsWith("eval/") ? NextShape
        : null;

    [Fact]
    public void EveryTopLevelSectionIsKnown()
    {
        var unknown = Spec.RootElement.EnumerateObject().Select(p => p.Name).Except(KnownTopLevel).ToList();
        Assert.True(unknown.Count == 0, "unknown top-level sections: " + string.Join(", ", unknown));
    }

    [Fact]
    public void EveryCaseIsFullyChecked()
    {
        var problems = new List<string>();
        foreach (var (path, section) in CaseSections())
        {
            if (ShapeOf(path) is not { } shape)
            {
                problems.Add($"{path}: unknown section");
                continue;
            }
            if (!section.TryGetProperty("tests", out var tests))
            {
                problems.Add($"{path}: no tests");
                continue;
            }
            foreach (var tc in tests.EnumerateArray())
            {
                var label = $"{path}/{(tc.TryGetProperty("name", out var n) ? n.GetString() : "?")}";
                if (!shape.HasAssertion(tc))
                {
                    problems.Add($"{label}: no assertion this runner checks");
                }
                var extra = tc.EnumerateObject().Select(f => f.Name).Except(shape.Fields).Except(Labels).ToList();
                if (extra.Count > 0)
                {
                    problems.Add($"{label}: fields this runner does not check: {string.Join(", ", extra)}");
                }
            }
        }
        Assert.True(problems.Count == 0, string.Join("\n", problems));
    }

    private static JsonElement Invariants => Spec.RootElement.GetProperty("invariants");

    public static TheoryData<string, string, string> GetInvariantTests()
    {
        var data = new TheoryData<string, string, string>();
        foreach (var tc in Invariants.GetProperty("tests").EnumerateArray())
        {
            var name = tc.GetProperty("name").GetString()!;
            var expression = tc.GetProperty("expression").GetString()!;
            var now = tc.GetProperty("now").GetString()!;
            data.Add(name, expression, now);
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(GetInvariantTests))]
    public void InvariantTests(string name, string expression, string nowStr)
    {
        var s = Schedule.Parse(expression);
        var now = ParseZonedDateTime(nowStr);
        var count = Invariants.GetProperty("count").GetInt32();

        var violations = Invariants.GetProperty("rules").EnumerateObject()
            .Select(rule => (rule.Name, Violation: InvariantRules.TryGetValue(rule.Name, out var check)
                ? check(s, now, count)
                : "rule is not implemented by this runner"))
            .Where(v => v.Violation is not null)
            .Select(v => $"{name} [{v.Name}]: {v.Violation}")
            .ToList();

        Assert.True(violations.Count == 0, $"'{expression}' from {nowStr}\n" + string.Join("\n", violations));
    }

    private static readonly Dictionary<string, Func<Schedule, DateTimeOffset, int, string?>> InvariantRules = new()
    {
        ["next_matches"] = (s, now, _) => NextMatches(s, now),
        ["next_after_now"] = (s, now, _) => NextAfterNow(s, now),
        ["next_n_chain"] = NextNChain,
        ["occurrences_prefix"] = OccurrencesPrefix,
        ["between_window"] = BetweenWindow,
        ["prev_inverse"] = PrevInverse,
        ["prev_before_now"] = (s, now, _) => PrevBeforeNow(s, now),
        ["display_roundtrip"] = (s, _, _) => DisplayRoundtrip(s),
    };

    private static string? NextMatches(Schedule s, DateTimeOffset now)
    {
        var next = s.NextFrom(now);
        return next is { } t && !s.Matches(t) ? $"matches({Show(t)}) is false" : null;
    }

    private static string? NextAfterNow(Schedule s, DateTimeOffset now)
    {
        var next = s.NextFrom(now);
        return next is { } t && t <= now ? $"nextFrom(now) is {Show(t)}, not after now" : null;
    }

    private static string? NextNChain(Schedule s, DateTimeOffset now, int count)
    {
        var list = s.NextNFrom(now, count);
        var first = s.NextFrom(now);
        if (list.Count == 0)
        {
            return first is null ? null : $"empty but nextFrom(now) is {Show(first)}";
        }
        if (list[0] != first)
        {
            return $"starts with {Show(list[0])} but nextFrom(now) is {Show(first)}";
        }
        for (var i = 1; i < list.Count; i++)
        {
            if (list[i] <= list[i - 1])
            {
                return $"not strictly increasing at {i}: {Show(list[i - 1])} then {Show(list[i])}";
            }
            var next = s.NextFrom(list[i - 1]);
            if (list[i] != next)
            {
                return $"element {i} is {Show(list[i])} but nextFrom({Show(list[i - 1])}) is {Show(next)}";
            }
        }
        return null;
    }

    private static string? OccurrencesPrefix(Schedule s, DateTimeOffset now, int count)
    {
        var list = s.NextNFrom(now, count);
        var taken = s.Occurrences(now).Take(count).ToList();
        return taken.SequenceEqual(list) ? null : $"occurrences gives {Show(taken)} but nextNFrom gives {Show(list)}";
    }

    private static string? BetweenWindow(Schedule s, DateTimeOffset now, int count)
    {
        var list = s.NextNFrom(now, count);
        if (list.Count == 0)
        {
            return null;
        }
        var between = s.Between(now, list[^1]).ToList();
        return between.SequenceEqual(list) ? null : $"between gives {Show(between)} but nextNFrom gives {Show(list)}";
    }

    private static string? PrevInverse(Schedule s, DateTimeOffset now, int count)
    {
        var list = s.NextNFrom(now, count);
        for (var i = 1; i < list.Count; i++)
        {
            var prev = s.PreviousFrom(list[i]);
            if (prev != list[i - 1])
            {
                return $"previousFrom({Show(list[i])}) is {Show(prev)}, expected {Show(list[i - 1])}";
            }
        }
        return null;
    }

    private static string? PrevBeforeNow(Schedule s, DateTimeOffset now)
    {
        if (s.PreviousFrom(now) is not { } p)
        {
            return null;
        }
        if (p >= now)
        {
            return $"previousFrom(now) is {Show(p)}, not before now";
        }
        if (!s.Matches(p))
        {
            return $"matches({Show(p)}) is false";
        }
        var next = s.NextFrom(p);
        return next is { } n && n < now ? $"nextFrom({Show(p)}) is {Show(n)}, earlier than now" : null;
    }

    private static string? DisplayRoundtrip(Schedule s)
    {
        var display = s.ToString();
        var again = Schedule.Parse(display).ToString();
        return again == display ? null : $"'{display}' re-displays as '{again}'";
    }

    private static string Show(DateTimeOffset? t) => t?.ToString("o") ?? "null";

    private static string Show(IEnumerable<DateTimeOffset> ts) => "[" + string.Join(", ", ts.Select(t => Show(t))) + "]";

    [GeneratedRegex(@"^(.+?)\[([^\]]+)\]$")]
    private static partial Regex ZdtPattern();

    private static DateTimeOffset ParseZonedDateTime(string s)
    {
        var match = ZdtPattern().Match(s);
        if (!match.Success)
        {
            return DateTimeOffset.Parse(s);
        }

        var isoStr = match.Groups[1].Value;
        var tzName = match.Groups[2].Value;

        var parsed = DateTimeOffset.Parse(isoStr);
        var tz = TimeZoneInfo.FindSystemTimeZoneById(tzName);
        return TimeZoneInfo.ConvertTime(parsed, tz);
    }
}
