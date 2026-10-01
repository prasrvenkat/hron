using Xunit;

namespace Hron.Tests;

/// <summary>
/// spec/README.md, "Timestamps and counts" and "Supported range", for what the conformance suite
/// cannot write as a string: DateTimeOffset's own limits, and the offset of every result across
/// DST changes.
/// </summary>
public class TimestampTest
{
    private static readonly TimeSpan Fourteen = TimeSpan.FromHours(14);

    private static readonly DateTimeOffset Now = new(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);

    private static readonly string[] EdgeExpressions =
    [
        "every day at 09:00",
        "every day at 00:00 in Pacific/Kiritimati",
        "every day at 23:59 in Etc/GMT+12",
        "every 1 min from 00:00 to 23:59 in America/New_York",
        "every year on jan 1 at 00:00 in Pacific/Kiritimati",
        "every year on dec 31 at 23:59 in Etc/GMT+12",
    ];

    private static readonly Dictionary<string, DateTimeOffset> PlatformLimits = new()
    {
        ["MinValue"] = DateTimeOffset.MinValue,
        ["MinValue wall time at -14:00"] = new(DateTime.MinValue, -Fourteen),
        ["MinValue instant at +14:00"] = new(DateTime.MinValue.AddHours(14), Fourteen),
        ["MaxValue"] = DateTimeOffset.MaxValue,
        ["MaxValue wall time at +14:00"] = new(DateTime.MaxValue, Fourteen),
        ["MaxValue instant at -14:00"] = new(DateTime.MaxValue.AddHours(-14), -Fourteen),
    };

    public static TheoryData<string, string> EdgeCases()
    {
        var data = new TheoryData<string, string>();
        foreach (var expression in EdgeExpressions)
        {
            foreach (var limit in PlatformLimits.Keys)
            {
                data.Add(expression, limit);
            }
        }
        return data;
    }

    [Theory]
    [MemberData(nameof(EdgeCases))]
    public void PlatformLimitsAreOutsideTheSupportedRange(string expression, string limit)
    {
        var schedule = Schedule.Parse(expression);
        var t = PlatformLimits[limit];

        Assert.Null(schedule.NextFrom(t));
        Assert.Null(schedule.PreviousFrom(t));
        Assert.False(schedule.Matches(t));
        Assert.Empty(schedule.NextNFrom(t, 3));
        Assert.Empty(schedule.NextNFrom(t, int.MaxValue));
        Assert.Empty(schedule.Occurrences(t));
        Assert.Empty(schedule.Between(t, Now));
        Assert.Empty(schedule.Between(Now, t));
        Assert.Empty(schedule.Between(t, t));
    }

    public static TheoryData<string> ZonedExpressions() =>
    [
        "every day at 01:30, 02:30, 09:00 in America/New_York",
        "every day at 01:30, 02:30, 09:00 in Europe/London",
        "every day at 01:45, 02:15, 09:00 in Australia/Lord_Howe",
        "every day at 09:00 in Asia/Kolkata",
        "every 90 min from 00:00 to 23:59 in America/St_Johns",
        "every day at 09:00 in UTC",
    ];

    [Theory]
    [MemberData(nameof(ZonedExpressions))]
    public void ResultsCarryTheScheduleZoneOffset(string expression)
    {
        var schedule = Schedule.Parse(expression);
        var zone = TimeZoneInfo.FindSystemTimeZoneById(schedule.Timezone!);
        var from = new DateTimeOffset(2026, 3, 1, 21, 0, 0, TimeSpan.FromHours(9));
        var to = new DateTimeOffset(2026, 4, 10, 0, 0, 0, -Fourteen);

        foreach (var result in AllResults(schedule, from, to))
        {
            Assert.Equal(zone.GetUtcOffset(result), result.Offset);
        }
    }

    [Fact]
    public void ResultsWithoutAZoneAreInUtc()
    {
        var schedule = Schedule.Parse("every day at 01:30, 02:30, 09:00");
        var from = new DateTimeOffset(2026, 3, 1, 21, 0, 0, TimeSpan.FromHours(9));
        var to = new DateTimeOffset(2026, 4, 10, 0, 0, 0, -Fourteen);

        foreach (var result in AllResults(schedule, from, to))
        {
            Assert.Equal(TimeSpan.Zero, result.Offset);
        }
    }

    private static List<DateTimeOffset> AllResults(Schedule schedule, DateTimeOffset from, DateTimeOffset to)
    {
        var results = new List<DateTimeOffset>();
        results.AddRange(schedule.NextNFrom(from, 100));
        results.AddRange(schedule.Occurrences(from).Take(100));
        results.AddRange(schedule.Between(from, to));
        results.Add(schedule.NextFrom(from)!.Value);
        results.Add(schedule.PreviousFrom(to)!.Value);
        Assert.True(results.Count > 200);
        return results;
    }

    [Fact]
    public void NextNFromIsEmptyForTheMostNegativeCount()
    {
        Assert.Empty(Schedule.Parse("every day at 09:00").NextNFrom(Now, int.MinValue));
    }
}

/// <summary>
/// Changes the host's local zone, which is process-wide, so nothing else runs beside it. On Unix
/// .NET reads the TZ variable when TimeZoneInfo.Local is next asked for.
/// </summary>
[CollectionDefinition(nameof(HostZoneTest), DisableParallelization = true)]
[Collection(nameof(HostZoneTest))]
public class HostZoneTest
{
    [Fact]
    public void DateTimeArgumentsAreReadAsHostLocalTime()
    {
        var original = Environment.GetEnvironmentVariable("TZ");
        Environment.SetEnvironmentVariable("TZ", "Asia/Tokyo");
        TimeZoneInfo.ClearCachedData();
        try
        {
            Assert.Equal(TimeSpan.FromHours(9), TimeZoneInfo.Local.BaseUtcOffset);
            var schedule = Schedule.Parse("every day at 09:00 in America/New_York");
            // 21:00 in Tokyo is 07:00 in New York, before that day's 09:00; 21:00 UTC is after it.
            var nineInNewYork = new DateTimeOffset(2026, 2, 6, 9, 0, 0, -TimeSpan.FromHours(5));
            var unspecified = new DateTime(2026, 2, 6, 21, 0, 0, DateTimeKind.Unspecified);
            var local = new DateTime(2026, 2, 6, 21, 0, 0, DateTimeKind.Local);
            var utc = new DateTime(2026, 2, 6, 21, 0, 0, DateTimeKind.Utc);

            Assert.Equal(nineInNewYork, schedule.NextFrom(unspecified));
            Assert.Equal(nineInNewYork, schedule.NextFrom(local));
            Assert.Equal(nineInNewYork.AddDays(1), schedule.NextFrom(utc));
            Assert.True(schedule.Matches(new DateTime(2026, 2, 6, 23, 0, 30, DateTimeKind.Unspecified)));
        }
        finally
        {
            Environment.SetEnvironmentVariable("TZ", original);
            TimeZoneInfo.ClearCachedData();
        }
    }
}
