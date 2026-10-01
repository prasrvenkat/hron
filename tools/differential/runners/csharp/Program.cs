using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Hron;

for (string? line; (line = Console.ReadLine()) != null;)
{
    var c = JsonNode.Parse(line)!.AsObject();
    var start = Stopwatch.GetTimestamp();
    var outcome = Run(c);
    outcome["micros"] = (long)Stopwatch.GetElapsedTime(start).TotalMicroseconds;
    outcome["id"] = c["id"]!.GetValue<string>();
    Console.WriteLine(JsonSerializer.Serialize(outcome));
}

static Dictionary<string, object?> Run(JsonObject c)
{
    try
    {
        return new() { ["ok"] = true, ["result"] = Evaluate(c) };
    }
    catch (HronException e)
    {
        return new()
        {
            ["ok"] = false,
            ["error"] = new
            {
                kind = e.Kind.ToString().ToLowerInvariant(),
                message = e.Message,
                span = e.Span is { } s ? new[] { s.Start, s.End } : null,
                suggestion = e.Suggestion,
            },
        };
    }
    catch (Exception e)
    {
        return new() { ["ok"] = false, ["error"] = new { kind = "crash", message = e.GetType().Name + ": " + e.Message } };
    }
}

static object? Evaluate(JsonObject c)
{
    var op = c["op"]!.GetValue<string>();
    var expr = c["expr"]!.GetValue<string>();
    if (op == "fromCron")
    {
        return Schedule.FromCron(expr).ToString();
    }
    var schedule = Schedule.Parse(expr);
    // DateTimeOffset carries an offset but no zone name, so the schedule's zone is assumed.
    var zone = schedule.Timezone ?? "UTC";
    string? Format(DateTimeOffset? t) => t is { } v
        ? v.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture) + $"[{zone}]"
        : null;
    DateTimeOffset Time(string field) => ParseZoned(c[field]!.GetValue<string>());
    int N() => c["n"]!.GetValue<int>();

    return op switch
    {
        "parse" => schedule.ToString(),
        "toCron" => schedule.ToCron(),
        "next" => Format(schedule.NextFrom(Time("now"))),
        "nextN" => schedule.NextNFrom(Time("now"), N()).Select(t => Format(t)).ToList(),
        "prev" => Format(schedule.PreviousFrom(Time("now"))),
        "matches" => schedule.Matches(Time("datetime")),
        "between" => schedule.Between(Time("from"), Time("to")).Select(t => Format(t)).ToList(),
        "occurrences" => schedule.Occurrences(Time("from")).Take(N()).Select(t => Format(t)).ToList(),
        _ => throw new ArgumentException($"unknown op {op}"),
    };
}

static DateTimeOffset ParseZoned(string s)
{
    var match = Regex.Match(s, @"^(.+)\[(.+)\]$");
    var instant = DateTimeOffset.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
    return TimeZoneInfo.ConvertTimeBySystemTimeZoneId(instant, match.Groups[2].Value);
}
