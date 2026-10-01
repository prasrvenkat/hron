namespace Hron.Eval;

/// <summary>
/// A slot a spring-forward gap skips (spec/README.md, "Interval slots in a spring-forward gap")
/// keys at the instant its gap ends, so keys never decrease in wall-clock order and one binary
/// search finds the slots on either side of an instant.
/// </summary>
internal readonly struct Slot
{
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
