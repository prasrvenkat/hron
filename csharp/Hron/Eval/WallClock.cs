using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its first pass
/// (spec/README.md, "DST fall-back (ambiguous times)").
/// </summary>
/// <remarks>
/// Assumes at most one offset change within a day of a wall time, and gaps and overlaps of at most
/// a day (tzdata 2026c has no transitions closer than about 95 hours), so the offsets a day before
/// and a day after it are the only ones it can have.
/// </remarks>
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

    /// <summary>
    /// The wall-clock minutes of <paramref name="date"/> that can hold an instant beyond
    /// <paramref name="now"/> in <paramref name="direction"/>. A wall time w fires at w − o for one
    /// of the date's offsets o, so it is after now only if w &gt; now + min(o) and before now only
    /// if w &lt; now + max(o); resolving the other minutes, the costly part, can be skipped.
    /// </summary>
    public static (long Earliest, long Latest) MinutesWorthResolving(DateOnly date, DateTimeOffset now, TimeZoneInfo zone, Direction direction)
    {
        var midnight = WallTicks(date, 0);
        var before = OffsetAt(midnight - TimeSpan.TicksPerDay, zone).Ticks;
        var after = OffsetAt(midnight + 2 * TimeSpan.TicksPerDay, zone).Ticks;
        var sinceMidnight = now.UtcTicks - midnight;
        return direction == Direction.Forward
            ? (Calendar.FloorDiv(sinceMidnight + Math.Min(before, after), TimeSpan.TicksPerMinute), long.MaxValue)
            : (long.MinValue, -Calendar.FloorDiv(-(sinceMidnight + Math.Max(before, after)), TimeSpan.TicksPerMinute));
    }

    public static DateOnly LocalDate(DateTimeOffset t, TimeZoneInfo zone)
    {
        return DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(t, zone).DateTime);
    }

    private static TimeSpan OffsetAt(long utcTicks, TimeZoneInfo zone)
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
        if (!SupportedRange.InSupportedRange(utcTicks))
        {
            return null;
        }
        return TimeZoneInfo.ConvertTime(new DateTimeOffset(utcTicks, TimeSpan.Zero), zone);
    }
}
