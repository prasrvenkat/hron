using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its first pass
/// (spec/README.md, "DST fall-back (ambiguous times)").
/// </summary>
internal static class WallClock
{
    public const int MinutesPerHour = 60;

    /// <summary>
    /// The instant <paramref name="time"/> names on <paramref name="date"/>, shifted forward by the
    /// gap's length when it falls in a spring-forward gap (spec/README.md, "DST spring-forward
    /// (gaps)"). Null outside the supported range.
    /// </summary>
    public static DateTimeOffset? FixedTimeOn(DateOnly date, TimeOfDay time, TimeZoneInfo zone)
    {
        var (utcTicks, _) = Resolve(WallTicks(date, time.TotalMinutes), zone);
        return InstantInRange(utcTicks, zone);
    }

    /// <summary>
    /// The instant of the interval slot <paramref name="minute"/> minutes after midnight on
    /// <paramref name="date"/>, or null when that wall time falls in a spring-forward gap
    /// (spec/README.md, "Interval slots in a spring-forward gap") or outside the supported range.
    /// </summary>
    public static DateTimeOffset? SlotOn(DateOnly date, long minute, TimeZoneInfo zone)
    {
        var (utcTicks, inGap) = Resolve(WallTicks(date, minute), zone);
        return inGap ? null : InstantInRange(utcTicks, zone);
    }

    public static DateOnly LocalDate(DateTimeOffset t, TimeZoneInfo zone)
    {
        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(t, zone).DateTime);
    }

    public static TimeSpan OffsetAt(long utcTicks, TimeZoneInfo zone)
    {
        var clamped = Math.Clamp(utcTicks, DateTime.MinValue.Ticks, DateTime.MaxValue.Ticks);
        return zone.GetUtcOffset(new DateTime(clamped, DateTimeKind.Utc));
    }

    private static long WallTicks(DateOnly date, long minute)
    {
        return date.ToDateTime(TimeOnly.MinValue).Ticks + minute * TimeSpan.TicksPerMinute;
    }

    /// <summary>
    /// Resolves a wall time from UTC offsets, which TimeZoneInfo reports correctly even where
    /// IsInvalidTime and its adjustment rules do not (base-offset changes such as Pyongyang 2018
    /// and Caracas 2016). The wall time exists at wall − o for each offset o around it that is in
    /// force at that instant; with none it is in a gap, shifted by the offset from before it.
    /// Assumes at most one offset change within a day of the wall time, and gaps and overlaps of
    /// at most a day (tzdata 2026c has no transitions closer than about 95 hours).
    /// </summary>
    private static (long UtcTicks, bool InGap) Resolve(long wallTicks, TimeZoneInfo zone)
    {
        var before = OffsetAt(wallTicks - TimeSpan.TicksPerDay, zone);
        var after = OffsetAt(wallTicks + TimeSpan.TicksPerDay, zone);
        long? firstPass = null;
        foreach (var offset in new[] { before, after })
        {
            var utc = wallTicks - offset.Ticks;
            if (OffsetAt(utc, zone) == offset && (firstPass is null || utc < firstPass))
            {
                firstPass = utc;
            }
        }
        return firstPass is { } ticks ? (ticks, false) : (wallTicks - before.Ticks, true);
    }

    private static DateTimeOffset? InstantInRange(long utcTicks, TimeZoneInfo zone)
    {
        if (!Evaluator.InSupportedRange(utcTicks))
        {
            return null;
        }
        return TimeZoneInfo.ConvertTime(new DateTimeOffset(utcTicks, TimeSpan.Zero), zone);
    }
}
