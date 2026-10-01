using System.Buffers.Binary;
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
    // DateTimeOffset carries an offset but no zone name, so a result is checked against the
    // schedule zone's offset and printed with that zone's name.
    var zone = schedule.Timezone ?? "UTC";
    string? Format(DateTimeOffset? t) => t is { } v ? FormatZoned(v, zone) : null;
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

// DateTimeOffset.Parse rejects an offset with seconds, so the offset is applied here.
static DateTimeOffset ParseZoned(string s)
{
    var match = Regex.Match(s, @"^(.+?)(?:Z|([+-])(\d\d:\d\d(?::\d\d)?))\[(.+)\]$");
    var wall = DateTime.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
    var offset = match.Groups[3].Success
        ? TimeSpan.Parse(match.Groups[3].Value, CultureInfo.InvariantCulture)
        : TimeSpan.Zero;
    var utc = match.Groups[2].Value == "-" ? wall + offset : wall - offset;
    var instant = new DateTimeOffset(utc, TimeSpan.Zero);
    return TimeZoneInfo.ConvertTimeBySystemTimeZoneId(instant, match.Groups[4].Value);
}

static string FormatZoned(DateTimeOffset t, string zone)
{
    if (t.Offset != TimeZoneInfo.FindSystemTimeZoneById(zone).GetUtcOffset(t))
    {
        throw new InvalidOperationException($"{t:o} is not in {zone}");
    }
    var offset = Offsets.Exact(t, zone);
    var wall = (t.UtcDateTime + offset).ToString("yyyy-MM-dd'T'HH:mm:ss", CultureInfo.InvariantCulture);
    var sign = offset < TimeSpan.Zero ? "-" : "+";
    var digits = offset.Seconds == 0 ? @"hh\:mm" : @"hh\:mm\:ss";
    return $"{wall}{sign}{offset.ToString(digits, CultureInfo.InvariantCulture)}[{zone}]";
}

// TimeZoneInfo keeps a zone's offsets in whole minutes, as DateTimeOffset does, so the exact offset
// is read from the TZif file TimeZoneInfo reads on Unix. After the file's last transition its POSIX rule
// applies, whose offsets tzdata writes in whole minutes, so TimeZoneInfo's offset is used there.
static class Offsets
{
    private static readonly Dictionary<string, (long[] Times, int[] Offsets, int Initial)> Zones = [];

    public static TimeSpan Exact(DateTimeOffset t, string zone)
    {
        if (!Zones.TryGetValue(zone, out var tzif))
        {
            Zones[zone] = tzif = Read(zone);
        }
        var (times, offsets, initial) = tzif;
        var seconds = t.ToUnixTimeSeconds();
        if (times.Length == 0 || seconds >= times[^1])
        {
            return TimeZoneInfo.FindSystemTimeZoneById(zone).GetUtcOffset(t);
        }
        var found = Array.BinarySearch(times, seconds);
        var last = found >= 0 ? found : ~found - 1;
        return TimeSpan.FromSeconds(last < 0 ? initial : offsets[last]);
    }

    private static (long[] Times, int[] Offsets, int Initial) Read(string zone)
    {
        var dir = Environment.GetEnvironmentVariable("TZDIR") ?? "/usr/share/zoneinfo";
        var path = Path.Combine(dir, zone);
        // Without a zoneinfo file (Windows) or a 64-bit body (TZif version 1), TimeZoneInfo answers alone.
        if (!File.Exists(path))
        {
            return ([], [], 0);
        }
        var data = File.ReadAllBytes(path);
        if (data[4] == 0)
        {
            return ([], [], 0);
        }
        int Int32(int at) => BinaryPrimitives.ReadInt32BigEndian(data.AsSpan(at));
        var header = 44 + Int32(32) * 5 + Int32(36) * 6 + Int32(40) + Int32(28) * 8 + Int32(24) + Int32(20);
        var count = Int32(header + 32);
        var body = header + 44;
        var types = body + count * 9;
        var times = new long[count];
        var offsets = new int[count];
        for (var i = 0; i < count; i++)
        {
            times[i] = BinaryPrimitives.ReadInt64BigEndian(data.AsSpan(body + i * 8));
            offsets[i] = Int32(types + data[body + count * 8 + i] * 6);
        }
        return (times, offsets, Int32(types));
    }
}
