using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// Wall-clock times on dates in a time zone. A wall time a fall-back repeats takes its first pass
/// (spec/README.md, "DST fall-back (ambiguous times)").
/// </summary>
/// <remarks>
/// Assumes at most one offset change within a day of a wall time, and gaps and overlaps of at most
/// a day (tzdata 2026c has no transitions closer than about 95 hours, longer than the three days
/// from a day before a date to a day after it), so the offsets a day before and a day after it, or
/// a day before and after its date, are the only ones it can have.
/// </remarks>
internal static class WallClock
{
    public const int MinutesPerHour = 60;

    /// <summary>
    /// The offsets in force before and after the one transition a wall time can be near.
    /// </summary>
    public readonly record struct Offsets(TimeSpan Before, TimeSpan After);

    /// <summary>
    /// The instant <paramref name="time"/> names on <paramref name="date"/>, shifted forward by the
    /// gap's length when it falls in a spring-forward gap (spec/README.md, "DST spring-forward
    /// (gaps)"). Null outside the supported range.
    /// </summary>
    public static DateTimeOffset? FixedTimeOn(DateOnly date, TimeOfDay time, TimeZoneInfo zone)
    {
        var wallTicks = WallTicks(date, time.TotalMinutes);
        var offsets = new Offsets(OffsetAt(wallTicks - TimeSpan.TicksPerDay, zone), OffsetAt(wallTicks + TimeSpan.TicksPerDay, zone));
        var (utcTicks, _) = Resolve(wallTicks, offsets, zone);
        return InstantInRange(utcTicks, zone);
    }

    /// <summary>
    /// The offsets a wall time on <paramref name="date"/> can have: those a day before the date
    /// begins and a day after it ends.
    /// </summary>
    public static Offsets OffsetsOn(DateOnly date, TimeZoneInfo zone)
    {
        var midnight = WallTicks(date, 0);
        return new Offsets(OffsetAt(midnight - TimeSpan.TicksPerDay, zone), OffsetAt(midnight + 2 * TimeSpan.TicksPerDay, zone));
    }

    /// <summary>
    /// The slot <paramref name="minute"/> minutes after midnight on <paramref name="date"/>, whose
    /// offsets are <paramref name="offsets"/>.
    /// </summary>
    public static Slot SlotOn(DateOnly date, long minute, Offsets offsets, TimeZoneInfo zone)
    {
        var wallTicks = WallTicks(date, minute);
        var (utcTicks, inGap) = Resolve(wallTicks, offsets, zone);
        return inGap ? Slot.Skipped(GapEnd(wallTicks, offsets, zone)) : Slot.At(utcTicks, zone);
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
    /// force at that instant, so with one offset around it, at wall − o; with none it is in a gap,
    /// shifted by the offset from before it.
    /// </summary>
    private static (long UtcTicks, bool InGap) Resolve(long wallTicks, Offsets offsets, TimeZoneInfo zone)
    {
        var (before, after) = offsets;
        if (before == after)
        {
            return (wallTicks - before.Ticks, false);
        }
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

    /// <summary>
    /// The instant the gap holding a wall time ends, rounded up to a whole second: the gap's
    /// transition lies after wall − after and at or before wall − before, where the offset leaves
    /// before. Offsets are whole seconds, so no instant a slot resolves to lies between the
    /// transition and the second it is rounded to.
    /// </summary>
    private static long GapEnd(long wallTicks, Offsets offsets, TimeZoneInfo zone)
    {
        var low = Calendar.FloorDiv(wallTicks - offsets.After.Ticks, TimeSpan.TicksPerSecond);
        var high = -Calendar.FloorDiv(offsets.Before.Ticks - wallTicks, TimeSpan.TicksPerSecond);
        while (high - low > 1)
        {
            var mid = low + (high - low) / 2;
            if (OffsetAt(mid * TimeSpan.TicksPerSecond, zone) == offsets.Before)
            {
                low = mid;
            }
            else
            {
                high = mid;
            }
        }
        return high * TimeSpan.TicksPerSecond;
    }

    public static DateTimeOffset? InstantInRange(long utcTicks, TimeZoneInfo zone)
    {
        if (!SupportedRange.InSupportedRange(utcTicks))
        {
            return null;
        }
        return TimeZoneInfo.ConvertTime(new DateTimeOffset(utcTicks, TimeSpan.Zero), zone);
    }
}
