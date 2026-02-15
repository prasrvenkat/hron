using System.Text.Json;
using Xunit;

namespace Hron.Tests;

/// <summary>
/// API conformance tests validating the public API matches spec/api.json.
/// </summary>
public class ApiConformanceTest
{
    private static readonly JsonDocument Spec;

    static ApiConformanceTest()
    {
        var specPath = Path.Combine(AppContext.BaseDirectory, "api.json");
        var json = File.ReadAllText(specPath);
        Spec = JsonDocument.Parse(json);
    }

    [Fact]
    public void SpecVersionIsPresent()
    {
        var version = Spec.RootElement.GetProperty("version").GetString();
        Assert.NotNull(version);
    }

    // Static methods

    [Fact]
    public void TestParse()
    {
        var s = Schedule.Parse("every day at 09:00");
        Assert.NotNull(s);
    }

    [Fact]
    public void TestFromCron()
    {
        var s = Schedule.FromCron("0 9 * * *");
        Assert.NotNull(s);
    }

    [Fact]
    public void TestValidate()
    {
        Assert.True(Schedule.Validate("every day at 09:00"));
        Assert.False(Schedule.Validate("not a schedule"));
    }

    // Instance methods

    [Fact]
    public void TestNextFrom()
    {
        var s = Schedule.Parse("every day at 09:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var result = s.NextFrom(now);
        Assert.NotNull(result);
    }

    [Fact]
    public void TestNextNFrom()
    {
        var s = Schedule.Parse("every day at 09:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var results = s.NextNFrom(now, 3);
        Assert.Equal(3, results.Count);
    }

    [Fact]
    public void TestPreviousFrom()
    {
        var s = Schedule.Parse("every day at 09:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var result = s.PreviousFrom(now);
        Assert.NotNull(result);
        // Previous should be today at 09:00
        Assert.Equal(6, result.Value.Day);
        Assert.Equal(9, result.Value.Hour);
    }

    [Fact]
    public void TestMatches()
    {
        var s = Schedule.Parse("every day at 09:00 in UTC");
        var matchTime = new DateTimeOffset(2026, 2, 10, 9, 0, 0, TimeSpan.Zero);
        var noMatchTime = new DateTimeOffset(2026, 2, 10, 10, 0, 0, TimeSpan.Zero);
        Assert.True(s.Matches(matchTime));
        Assert.False(s.Matches(noMatchTime));
    }

    [Fact]
    public void TestToCron()
    {
        var s = Schedule.Parse("every day at 09:00");
        var cron = s.ToCron();
        Assert.Equal("0 9 * * *", cron);
    }

    [Fact]
    public void TestToString()
    {
        var s = Schedule.Parse("every day at 9:00");
        Assert.Equal("every day at 09:00", s.ToString());
    }

    // Getters

    [Fact]
    public void TestTimezoneNone()
    {
        var s = Schedule.Parse("every day at 09:00");
        Assert.Null(s.Timezone);
    }

    [Fact]
    public void TestTimezonePresent()
    {
        var s = Schedule.Parse("every day at 09:00 in America/New_York");
        Assert.NotNull(s.Timezone);
        Assert.Equal("America/New_York", s.Timezone);
    }

    // Error types

    [Fact]
    public void TestErrorKinds()
    {
        Assert.Equal("lex", ErrorKind.Lex.ToValue());
        Assert.Equal("parse", ErrorKind.Parse.ToValue());
        Assert.Equal("eval", ErrorKind.Eval.ToValue());
        Assert.Equal("cron", ErrorKind.Cron.ToValue());
    }

    [Fact]
    public void TestLexError()
    {
        var err = HronException.Lex("test", new Span(0, 1), "input");
        Assert.Equal(ErrorKind.Lex, err.Kind);
        Assert.NotNull(err.Span);
        Assert.NotNull(err.Input);
    }

    [Fact]
    public void TestParseError()
    {
        var err = HronException.Parse("test", new Span(0, 1), "input", "suggestion");
        Assert.Equal(ErrorKind.Parse, err.Kind);
        Assert.NotNull(err.Span);
        Assert.NotNull(err.Input);
        Assert.NotNull(err.Suggestion);
    }

    [Fact]
    public void TestEvalError()
    {
        var err = HronException.Eval("test");
        Assert.Equal(ErrorKind.Eval, err.Kind);
        Assert.Null(err.Span);
    }

    [Fact]
    public void TestCronError()
    {
        var err = HronException.Cron("test");
        Assert.Equal(ErrorKind.Cron, err.Kind);
        Assert.Null(err.Span);
    }

    [Fact]
    public void TestDisplayRich()
    {
        var err = HronException.Parse("test error", new Span(0, 4), "test input");
        var rich = err.DisplayRich();
        Assert.NotEmpty(rich);
        Assert.Contains("error:", rich);
    }

    // Behavioral tests

    [Fact]
    public void TestExactTimeBoundary()
    {
        // If now equals an occurrence exactly, skip it
        var s = Schedule.Parse("every day at 12:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var next = s.NextFrom(now);
        Assert.NotNull(next);

        // Next should be tomorrow, not today
        Assert.Equal(7, next.Value.Day);
    }

    [Fact]
    public void TestIntervalAlignment()
    {
        var s = Schedule.Parse("every 3 days at 09:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var next = s.NextFrom(now);
        Assert.NotNull(next);

        // Feb 6 is aligned (day 20490 from epoch, 20490 % 3 = 0)
        // Since 09:00 has passed, next should be Feb 9
        Assert.Equal(9, next.Value.Day);
    }

    // Spec coverage tests - verify all api.json methods are implemented

    [Fact]
    public void SpecStaticMethodsExist()
    {
        var schedule = Spec.RootElement.GetProperty("schedule");
        var staticMethods = schedule.GetProperty("staticMethods");

        var expectedMethods = new Dictionary<string, string>
        {
            ["parse"] = nameof(Schedule.Parse),
            ["fromCron"] = nameof(Schedule.FromCron),
            ["validate"] = nameof(Schedule.Validate)
        };

        foreach (var method in staticMethods.EnumerateArray())
        {
            var name = method.GetProperty("name").GetString()!;
            Assert.True(expectedMethods.ContainsKey(name), $"Unmapped spec static method: {name}");
        }
    }

    [Fact]
    public void SpecInstanceMethodsExist()
    {
        var schedule = Spec.RootElement.GetProperty("schedule");
        var instanceMethods = schedule.GetProperty("instanceMethods");

        var expectedMethods = new Dictionary<string, string>
        {
            ["nextFrom"] = nameof(Schedule.NextFrom),
            ["nextNFrom"] = nameof(Schedule.NextNFrom),
            ["previousFrom"] = nameof(Schedule.PreviousFrom),
            ["matches"] = nameof(Schedule.Matches),
            ["occurrences"] = nameof(Schedule.Occurrences),
            ["between"] = nameof(Schedule.Between),
            ["toCron"] = nameof(Schedule.ToCron),
            ["toString"] = "ToString"
        };

        foreach (var method in instanceMethods.EnumerateArray())
        {
            var name = method.GetProperty("name").GetString()!;
            Assert.True(expectedMethods.ContainsKey(name), $"Unmapped spec instance method: {name}");
        }
    }

    [Fact]
    public void SpecGettersExist()
    {
        var schedule = Spec.RootElement.GetProperty("schedule");
        var getters = schedule.GetProperty("getters");

        var expectedGetters = new Dictionary<string, string>
        {
            ["timezone"] = nameof(Schedule.Timezone)
        };

        foreach (var getter in getters.EnumerateArray())
        {
            var name = getter.GetProperty("name").GetString()!;
            Assert.True(expectedGetters.ContainsKey(name), $"Unmapped spec getter: {name}");
        }
    }

    [Fact]
    public void SpecErrorKindsMatch()
    {
        var error = Spec.RootElement.GetProperty("error");
        var kinds = error.GetProperty("kinds");

        var expectedKinds = new HashSet<string> { "lex", "parse", "eval", "cron" };

        foreach (var kind in kinds.EnumerateArray())
        {
            var name = kind.GetString()!;
            Assert.True(expectedKinds.Contains(name), $"Unexpected error kind in spec: {name}");
        }
    }

    [Fact]
    public void SpecErrorConstructorsExist()
    {
        var error = Spec.RootElement.GetProperty("error");
        var constructors = error.GetProperty("constructors");

        var expectedConstructors = new Dictionary<string, string>
        {
            ["lex"] = nameof(HronException.Lex),
            ["parse"] = nameof(HronException.Parse),
            ["eval"] = nameof(HronException.Eval),
            ["cron"] = nameof(HronException.Cron)
        };

        foreach (var constructor in constructors.EnumerateArray())
        {
            var name = constructor.GetString()!;
            Assert.True(expectedConstructors.ContainsKey(name), $"Unmapped spec error constructor: {name}");
        }
    }

    [Fact]
    public void SpecErrorMethodsExist()
    {
        var error = Spec.RootElement.GetProperty("error");
        var methods = error.GetProperty("methods");

        var expectedMethods = new Dictionary<string, string>
        {
            ["displayRich"] = nameof(HronException.DisplayRich)
        };

        foreach (var method in methods.EnumerateArray())
        {
            var name = method.GetProperty("name").GetString()!;
            Assert.True(expectedMethods.ContainsKey(name), $"Unmapped spec error method: {name}");
        }
    }
}
