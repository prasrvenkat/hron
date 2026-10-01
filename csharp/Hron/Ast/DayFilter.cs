namespace Hron.Ast;

public sealed record DayFilter(DayFilterKind Kind, IReadOnlyList<Weekday> Days)
{
    public static DayFilter Every() => new(DayFilterKind.Every, []);

    public static DayFilter Weekday() => new(DayFilterKind.Weekday, []);

    public static DayFilter Weekend() => new(DayFilterKind.Weekend, []);

    public static DayFilter SpecificDays(IReadOnlyList<Weekday> days) => new(DayFilterKind.Days, days);
}

public enum DayFilterKind
{
    Every,
    Weekday,
    Weekend,
    Days
}
