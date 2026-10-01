namespace Hron.Ast;

public enum IntervalUnit
{
    Minutes,
    Hours
}

public static class IntervalUnitExtensions
{
    /// <summary>
    /// Returns the unit as displayed after <paramref name="interval"/>, singular when it is 1.
    /// </summary>
    public static string Display(this IntervalUnit unit, int interval) => unit switch
    {
        IntervalUnit.Minutes => interval == 1 ? "minute" : "min",
        IntervalUnit.Hours => interval == 1 ? "hour" : "hours",
        _ => throw new ArgumentOutOfRangeException(nameof(unit))
    };
}
