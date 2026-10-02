namespace Hron.Ast;

/// <summary>
/// A <see cref="DayOfMonthSpecKind.Single"/> day is <c>Day</c>; a <see cref="DayOfMonthSpecKind.Range"/>
/// runs from <c>Start</c> to <c>End</c>, both included. The fields the kind does not use are 0.
/// </summary>
public sealed record DayOfMonthSpec(DayOfMonthSpecKind Kind, int Day, int Start, int End)
{
    public DayOfMonthSpecKind Kind { get; } = Kind;

    public int Day { get; } = Day;

    public int Start { get; } = Start;

    public int End { get; } = End;

    internal static DayOfMonthSpec Single(int day) => new(DayOfMonthSpecKind.Single, day, 0, 0);

    internal static DayOfMonthSpec Range(int start, int end) => new(DayOfMonthSpecKind.Range, 0, start, end);

    internal IReadOnlyList<int> Expand()
    {
        if (Kind == DayOfMonthSpecKind.Single)
        {
            return [Day];
        }

        var days = new List<int>(Math.Max(End - Start + 1, 0));
        for (var i = Start; i <= End; i++)
        {
            days.Add(i);
        }
        return days;
    }
}

public enum DayOfMonthSpecKind
{
    Single,
    Range
}
