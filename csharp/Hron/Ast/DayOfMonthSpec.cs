namespace Hron.Ast;

/// <summary>
/// Represents a single day or range of days within a month.
/// </summary>
public sealed record DayOfMonthSpec(DayOfMonthSpecKind Kind, int Day, int Start, int End)
{
    /// <summary>
    /// Creates a single day specification.
    /// </summary>
    public static DayOfMonthSpec Single(int day) => new(DayOfMonthSpecKind.Single, day, 0, 0);

    /// <summary>
    /// Creates a day range specification.
    /// </summary>
    public static DayOfMonthSpec Range(int start, int end) => new(DayOfMonthSpecKind.Range, 0, start, end);

    /// <summary>
    /// Returns all days in this specification.
    /// </summary>
    public IReadOnlyList<int> Expand()
    {
        if (Kind == DayOfMonthSpecKind.Single)
        {
            return [Day];
        }

        var days = new List<int>(End - Start + 1);
        for (var i = Start; i <= End; i++)
        {
            days.Add(i);
        }
        return days;
    }
}

/// <summary>
/// The type of day-of-month specification.
/// </summary>
public enum DayOfMonthSpecKind
{
    /// <summary>A single day.</summary>
    Single,
    /// <summary>A range of days.</summary>
    Range
}
