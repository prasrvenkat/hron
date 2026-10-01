namespace Hron.Eval;

/// <summary>
/// An occurrence a search found, with the local date it lands on.
/// </summary>
/// <remarks>
/// An occurrence lands on a first pass, from its scheduled date to the times' MaxShiftDays after
/// it, and first passes keep wall-clock order.
/// </remarks>
internal readonly record struct Occurrence(DateTimeOffset Instant, DateOnly Landing)
{
    /// <summary>
    /// How many dates past its scheduled date a fixed time can land: one shifted out of a gap
    /// before midnight lands on the next date.
    /// </summary>
    public const int MaxShiftDays = 1;

    /// <summary>
    /// How many dates behind a date that has begun now's wall date can read: from the second pass
    /// of a fall-back overlap that crosses midnight, one.
    /// </summary>
    private const int MaxOverlapDays = 1;

    /// <summary>
    /// The occurrence at <paramref name="instant"/>, which is in the schedule's zone.
    /// </summary>
    public static Occurrence At(DateTimeOffset instant) => new(instant, DateOnly.FromDateTime(instant.DateTime));

    /// <summary>
    /// Whether an occurrence scheduled on <paramref name="date"/>, landing at most
    /// <paramref name="shift"/> dates after it, can precede this one in
    /// <paramref name="direction"/>.
    /// </summary>
    public bool CouldBeat(DateOnly date, Direction direction, int shift) => direction switch
    {
        Direction.Forward => date <= Landing,
        _ => Landing.DayNumber - date.DayNumber <= shift
    };

    /// <summary>
    /// Whether every occurrence scheduled on <paramref name="date"/>, landing at most
    /// <paramref name="shift"/> dates after it, lies behind now, whose wall date is
    /// <paramref name="nowDate"/>, in <paramref name="direction"/>.
    /// </summary>
    public static bool IsBehind(DateOnly date, DateOnly nowDate, Direction direction, int shift) => direction switch
    {
        Direction.Forward => nowDate.DayNumber - date.DayNumber > shift,
        _ => date.DayNumber - nowDate.DayNumber > MaxOverlapDays
    };
}
