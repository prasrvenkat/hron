namespace Hron.Ast;

/// <summary>
/// <c>Days</c> lists the days when <c>Kind</c> is <see cref="DayFilterKind.Days"/>, and is empty otherwise.
/// </summary>
public sealed record DayFilter(DayFilterKind Kind, IReadOnlyList<Weekday> Days)
{
    public DayFilterKind Kind { get; } = Kind;

    public IReadOnlyList<Weekday> Days { get; } = PartList<Weekday>.Of(Days);

    internal static DayFilter Every() => new(DayFilterKind.Every, []);

    internal static DayFilter Weekday() => new(DayFilterKind.Weekday, []);

    internal static DayFilter Weekend() => new(DayFilterKind.Weekend, []);

    internal static DayFilter SpecificDays(IReadOnlyList<Weekday> days) => new(DayFilterKind.Days, days);
}

public enum DayFilterKind
{
    Every,
    Weekday,
    Weekend,
    Days
}
