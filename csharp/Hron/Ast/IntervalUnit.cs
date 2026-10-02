namespace Hron.Ast;

public enum IntervalUnit
{
    Minutes,
    Hours
}

internal static class IntervalUnitExtensions
{
    public static string Display(this IntervalUnit unit, int interval) => unit switch
    {
        IntervalUnit.Minutes => interval == 1 ? "minute" : "min",
        IntervalUnit.Hours => interval == 1 ? "hour" : "hours",
        _ => throw new ArgumentOutOfRangeException(nameof(unit))
    };
}
