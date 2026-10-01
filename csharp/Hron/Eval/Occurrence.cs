namespace Hron.Eval;

/// <summary>
/// An occurrence a search found, with the date it is scheduled on.
/// </summary>
internal readonly record struct Occurrence(DateTimeOffset Instant, DateOnly Date)
{
    /// <summary>
    /// How many dates past its scheduled date an occurrence can land: a fixed time shifted out of
    /// a gap before midnight lands on the next date.
    /// </summary>
    private const int MaxShiftDays = 1;

    /// <summary>
    /// Whether an occurrence scheduled on <paramref name="date"/> can precede <paramref name="best"/>
    /// in <paramref name="direction"/>, given that each lands at most MaxShiftDays after its date.
    /// </summary>
    public static bool CouldBeat(DateOnly date, Occurrence best, Direction direction)
    {
        return direction.Sign() * (date.DayNumber - best.Date.DayNumber) <= MaxShiftDays;
    }
}
