namespace Hron.Ast;

public sealed record DayOfMonthSpec(DayOfMonthSpecKind Kind, int Day, int Start, int End)
{
    public static DayOfMonthSpec Single(int day) => new(DayOfMonthSpecKind.Single, day, 0, 0);

    public static DayOfMonthSpec Range(int start, int end) => new(DayOfMonthSpecKind.Range, 0, start, end);

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

public enum DayOfMonthSpecKind
{
    Single,
    Range
}
