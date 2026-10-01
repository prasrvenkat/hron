namespace Hron.Eval;

/// <summary>
/// spec/README.md, "Supported range": from RangeStart inclusive to RangeEnd exclusive.
/// </summary>
internal static class SupportedRange
{
    public static readonly DateTimeOffset RangeStart = new(1, 1, 2, 0, 0, 0, TimeSpan.Zero);

    public static readonly DateTimeOffset RangeEnd = new(9999, 12, 30, 0, 0, 0, TimeSpan.Zero);

    public static bool InSupportedRange(DateTimeOffset t) => InSupportedRange(t.UtcTicks);

    public static bool InSupportedRange(long utcTicks) => utcTicks >= RangeStart.UtcTicks && utcTicks < RangeEnd.UtcTicks;
}
