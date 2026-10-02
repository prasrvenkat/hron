using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using Hron.Ast;
using Xunit;

namespace Hron.Tests;

public class ApiConformanceTest
{
    private static readonly string SpecJson = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "api.json"));
    private static readonly JsonDocument Spec = JsonDocument.Parse(SpecJson);

    private static readonly Dictionary<string, string> ScheduleNames = new()
    {
        ["parse"] = "Parse",
        ["fromCron"] = "FromCron",
        ["validate"] = "Validate",
        ["nextFrom"] = "NextFrom",
        ["nextNFrom"] = "NextNFrom",
        ["previousFrom"] = "PreviousFrom",
        ["matches"] = "Matches",
        ["occurrences"] = "Occurrences",
        ["between"] = "Between",
        ["toCron"] = "ToCron",
        ["toString"] = "ToString",
        ["equals"] = "Equals",
        ["timezone"] = "Timezone",
        ["expression"] = "Expression",
        ["except"] = "Except",
        ["until"] = "Until",
        ["starting"] = "Starting",
        ["during"] = "During",
    };

    private static readonly Dictionary<string, string> ErrorNames = new()
    {
        ["kind"] = "Kind",
        ["message"] = "Message",
        ["span"] = "Span",
        ["input"] = "Input",
        ["suggestion"] = "Suggestion",
        ["displayRich"] = "DisplayRich",
        ["lex"] = "Lex",
        ["parse"] = "Parse",
        ["eval"] = "Eval",
        ["cron"] = "Cron",
    };

    private static readonly Dictionary<string, Type> Types = new()
    {
        ["string"] = typeof(string),
        ["string?"] = typeof(string),
        ["bool"] = typeof(bool),
        ["int"] = typeof(int),
        ["Schedule"] = typeof(Schedule),
        ["ZonedDateTime"] = typeof(DateTimeOffset),
        ["ZonedDateTime?"] = typeof(DateTimeOffset?),
        ["ZonedDateTime[]"] = typeof(IReadOnlyList<DateTimeOffset>),
        ["Iterator<ZonedDateTime>"] = typeof(IEnumerable<DateTimeOffset>),
        ["ScheduleExpr"] = typeof(IScheduleExpr),
        ["Exception[]"] = typeof(IReadOnlyList<ExceptionSpec>),
        ["UntilSpec?"] = typeof(UntilSpec),
        ["Date?"] = typeof(string),
        ["MonthName[]"] = typeof(IReadOnlyList<MonthName>),
        ["ErrorKind"] = typeof(ErrorKind),
        ["Span?"] = typeof(Span?),
    };

    [Fact]
    public void SpecVersionIsPresent()
    {
        var version = Spec.RootElement.GetProperty("version").GetString();
        Assert.NotNull(version);
    }

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

    [Fact]
    public void TestExactTimeBoundary()
    {
        var s = Schedule.Parse("every day at 12:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var next = s.NextFrom(now);
        Assert.NotNull(next);

        Assert.Equal(7, next.Value.Day);
    }

    [Fact]
    public void TestIntervalAlignment()
    {
        var s = Schedule.Parse("every 3 days at 09:00 in UTC");
        var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);
        var next = s.NextFrom(now);
        Assert.NotNull(next);

        // Feb 6, 2026 is day 20490 from the epoch, a multiple of 3, so the next aligned day
        // after its 09:00 is Feb 9.
        Assert.Equal(9, next.Value.Day);
    }

    [Fact]
    public void EveryApiMemberExistsUnderItsCSharpName()
    {
        Assert.Empty(Problems(Spec.RootElement));
    }

    [Fact]
    public void AnApiMemberCSharpLacksIsAProblem()
    {
        var api = JsonNode.Parse(SpecJson)!;
        var schedule = api["schedule"]!;
        var error = api["error"]!;
        schedule["staticMethods"]!.AsArray().Add(new JsonObject { ["name"] = "fakeStatic", ["params"] = new JsonArray(), ["returns"] = "bool" });
        schedule["instanceMethods"]!.AsArray().Add(new JsonObject { ["name"] = "fakeMethod", ["params"] = new JsonArray(), ["returns"] = "bool" });
        schedule["getters"]!.AsArray().Add(new JsonObject { ["name"] = "fakeGetter", ["type"] = "string?" });
        error["properties"]!.AsArray().Add(new JsonObject { ["name"] = "fakeProperty", ["type"] = "string?" });
        error["methods"]!.AsArray().Add(new JsonObject { ["name"] = "fakeErrorMethod", ["params"] = new JsonArray(), ["returns"] = "string" });
        error["constructors"]!.AsArray().Add("fakeConstructor");
        error["kinds"]!.AsArray().Add("fakeKind");

        Assert.Equal(
            [
                "fakeStatic: no C# name",
                "fakeMethod: no C# name",
                "fakeGetter: no C# name",
                "fakeProperty: no C# name",
                "fakeErrorMethod: no C# name",
                "fakeConstructor: no C# name",
                "fakeKind: no C# name",
            ],
            Problems(JsonDocument.Parse(api.ToJsonString()).RootElement));
    }

    [Fact]
    public void AnApiSignatureCSharpDoesNotMatchIsAProblem()
    {
        var api = JsonNode.Parse(SpecJson)!;
        var methods = api["schedule"]!["instanceMethods"]!.AsArray();
        var nextNFrom = methods.Single(m => (string?)m!["name"] == "nextNFrom")!;
        nextNFrom["params"]![1]!["name"] = "count";
        var between = methods.Single(m => (string?)m!["name"] == "between")!;
        between["params"]!.AsArray().RemoveAt(1);
        var toCron = methods.Single(m => (string?)m!["name"] == "toCron")!;
        toCron["returns"] = "string?";
        var timezone = api["schedule"]!["getters"]!.AsArray().Single(g => (string?)g!["name"] == "timezone")!;
        timezone["type"] = "string";
        var kind = api["error"]!["properties"]!.AsArray().Single(p => (string?)p!["name"] == "kind")!;
        kind["type"] = "string";
        var matches = methods.Single(m => (string?)m!["name"] == "matches")!;
        matches["returns"] = "Boolean";
        api["error"]!["kinds"]!.AsArray().RemoveAt(3);

        Assert.Equal(
            [
                "nextNFrom: Schedule.NextNFrom takes (now, n), not (now, count)",
                "matches: no C# type for Boolean",
                "between: no Schedule.Between(DateTimeOffset)",
                "toCron: Schedule.ToCron returns String, nullable False, not string?",
                "timezone: Schedule.Timezone is String, nullable True, not string",
                "kind: HronException.Kind is ErrorKind, nullable False, not string",
                "ErrorKind.Cron is not in api.json",
            ],
            Problems(JsonDocument.Parse(api.ToJsonString()).RootElement));
    }

    private static List<string> Problems(JsonElement api)
    {
        var problems = new List<string>();
        var schedule = api.GetProperty("schedule");
        var error = api.GetProperty("error");

        foreach (var method in schedule.GetProperty("staticMethods").EnumerateArray())
        {
            CheckMethod(typeof(Schedule), BindingFlags.Static, method, ScheduleNames, problems);
        }
        foreach (var method in schedule.GetProperty("instanceMethods").EnumerateArray())
        {
            CheckMethod(typeof(Schedule), BindingFlags.Instance, method, ScheduleNames, problems);
            if (method.GetProperty("name").GetString() == "equals")
            {
                CheckEquality(problems);
            }
        }
        foreach (var getter in schedule.GetProperty("getters").EnumerateArray())
        {
            CheckProperty(typeof(Schedule), getter, ScheduleNames, problems);
        }
        foreach (var property in error.GetProperty("properties").EnumerateArray())
        {
            CheckProperty(typeof(HronException), property, ErrorNames, problems);
        }
        foreach (var method in error.GetProperty("methods").EnumerateArray())
        {
            CheckMethod(typeof(HronException), BindingFlags.Instance, method, ErrorNames, problems);
        }
        foreach (var constructor in error.GetProperty("constructors").EnumerateArray())
        {
            CheckConstructor(constructor.GetString()!, problems);
        }
        var kinds = error.GetProperty("kinds").EnumerateArray().Select(k => k.GetString()!).ToList();
        foreach (var kind in kinds)
        {
            CheckKind(kind, problems);
        }
        foreach (var kind in Enum.GetValues<ErrorKind>().Where(k => !kinds.Contains(k.ToValue())))
        {
            problems.Add($"ErrorKind.{kind} is not in api.json");
        }
        return problems;
    }

    private static void CheckMethod(Type type, BindingFlags binding, JsonElement spec, Dictionary<string, string> names, List<string> problems)
    {
        var name = spec.GetProperty("name").GetString()!;
        if (!names.TryGetValue(name, out var csName))
        {
            problems.Add($"{name}: no C# name");
            return;
        }
        var parameters = spec.GetProperty("params").EnumerateArray().ToList();
        var returns = spec.GetProperty("returns").GetString()!;
        var unknown = parameters.Select(p => p.GetProperty("type").GetString()!).Append(returns).Where(t => !Types.ContainsKey(t));
        if (unknown.Any())
        {
            problems.Add($"{name}: no C# type for {string.Join(", ", unknown)}");
            return;
        }
        var types = parameters.Select(p => Types[p.GetProperty("type").GetString()!]).ToArray();
        var method = type.GetMethod(csName, BindingFlags.Public | binding, types);
        if (method is null || method.DeclaringType != type)
        {
            problems.Add($"{name}: no {type.Name}.{csName}({string.Join(", ", types.Select(t => t.Name))})");
            return;
        }
        var specNames = parameters.Select(p => p.GetProperty("name").GetString()!).ToList();
        var csNames = method.GetParameters().Select(p => p.Name!).ToList();
        // C# writes the spec's "datetime" as dateTime.
        if (!csNames.SequenceEqual(specNames, StringComparer.OrdinalIgnoreCase))
        {
            problems.Add($"{name}: {type.Name}.{csName} takes ({string.Join(", ", csNames)}), not ({string.Join(", ", specNames)})");
        }
        var nullable = new NullabilityInfoContext().Create(method.ReturnParameter).ReadState == NullabilityState.Nullable;
        if (method.ReturnType != Types[returns] || nullable != returns.EndsWith('?'))
        {
            problems.Add($"{name}: {type.Name}.{csName} returns {method.ReturnType.Name}, nullable {nullable}, not {returns}");
        }
    }

    private static void CheckProperty(Type type, JsonElement spec, Dictionary<string, string> names, List<string> problems)
    {
        var name = spec.GetProperty("name").GetString()!;
        if (!names.TryGetValue(name, out var csName))
        {
            problems.Add($"{name}: no C# name");
            return;
        }
        var property = type.GetProperty(csName, BindingFlags.Public | BindingFlags.Instance);
        if (property is null)
        {
            problems.Add($"{name}: no {type.Name}.{csName}");
            return;
        }
        var specType = spec.GetProperty("type").GetString()!;
        if (!Types.ContainsKey(specType))
        {
            problems.Add($"{name}: no C# type for {specType}");
            return;
        }
        var nullable = new NullabilityInfoContext().Create(property).ReadState == NullabilityState.Nullable;
        if (property.PropertyType != Types[specType] || nullable != specType.EndsWith('?'))
        {
            problems.Add($"{name}: {type.Name}.{csName} is {property.PropertyType.Name}, nullable {nullable}, not {specType}");
        }
        if (property.SetMethod is not null)
        {
            problems.Add($"{name}: {type.Name}.{csName} has a setter");
        }
    }

    private static void CheckConstructor(string name, List<string> problems)
    {
        if (!ErrorNames.TryGetValue(name, out var csName))
        {
            problems.Add($"{name}: no C# name");
            return;
        }
        var factory = typeof(HronException).GetMethod(csName, BindingFlags.Public | BindingFlags.Static);
        if (factory is null || factory.ReturnType != typeof(HronException))
        {
            problems.Add($"{name}: no static HronException.{csName} returning HronException");
        }
    }

    private static void CheckKind(string name, List<string> problems)
    {
        if (!ErrorNames.TryGetValue(name, out var csName))
        {
            problems.Add($"{name}: no C# name");
            return;
        }
        if (!Enum.TryParse<ErrorKind>(csName, out var kind) || kind.ToValue() != name)
        {
            problems.Add($"{name}: no ErrorKind.{csName} whose ToValue() is {name}");
        }
    }

    /// <summary>
    /// The equality sentence of the csharp note in api.json.
    /// </summary>
    private static void CheckEquality(List<string> problems)
    {
        var schedule = typeof(Schedule);
        var members = new (string Name, MethodInfo? Method)[]
        {
            ("IEquatable<Schedule>.Equals", typeof(IEquatable<Schedule>).IsAssignableFrom(schedule)
                ? schedule.GetInterfaceMap(typeof(IEquatable<Schedule>)).TargetMethods.Single()
                : null),
            ("Equals(object)", schedule.GetMethod(nameof(Equals), [typeof(object)])),
            ("GetHashCode()", schedule.GetMethod(nameof(GetHashCode), Type.EmptyTypes)),
            ("operator ==", schedule.GetMethod("op_Equality", [schedule, schedule])),
            ("operator !=", schedule.GetMethod("op_Inequality", [schedule, schedule])),
        };
        foreach (var (name, method) in members.Where(m => m.Method?.DeclaringType != schedule))
        {
            problems.Add($"equals: Schedule does not declare {name}");
        }
    }
}
