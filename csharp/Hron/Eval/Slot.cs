namespace Hron.Eval;

/// <summary>
/// An interval slot on a date: where it sits in time, in UTC ticks, and its instant unless a
/// spring-forward gap skips it (spec/README.md, "Interval slots in a spring-forward gap"). A
/// skipped slot sits at the instant its gap ends, so keys never decrease in wall-clock order and
/// one binary search finds the slots on either side of an instant.
/// </summary>
internal readonly struct Slot
{
    /// <summary>
    /// The zone the slot's instant is in, or null when a gap skips it.
    /// </summary>
    private readonly TimeZoneInfo? _zone;

    private Slot(long key, TimeZoneInfo? zone)
    {
        Key = key;
        _zone = zone;
    }

    public long Key { get; }

    /// <summary>
    /// The slot's instant, built only when asked for: null when a gap skips it or it lies outside
    /// the supported range.
    /// </summary>
    public DateTimeOffset? Instant => _zone is null ? null : WallClock.InstantInRange(Key, _zone);

    public static Slot At(long utcTicks, TimeZoneInfo zone) => new(utcTicks, zone);

    public static Slot Skipped(long gapEnd) => new(gapEnd, null);
}
