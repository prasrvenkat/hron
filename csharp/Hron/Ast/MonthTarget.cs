namespace Hron.Ast;

public enum NearestDirection
{
    /// <summary>Always prefer following weekday (can cross to next month).</summary>
    Next,
    /// <summary>Always prefer preceding weekday (can cross to prev month).</summary>
    Previous
}

/// <summary>
/// <c>Kind</c> says which fields hold the target: <c>Specs</c> for <see cref="MonthTargetKind.Days"/>;
/// <c>NearestWeekdayDay</c> and <c>NearestWeekdayDirection</c> for
/// <see cref="MonthTargetKind.NearestWeekday"/>, the direction null for the closest weekday within the
/// month (cron's <c>W</c>); <c>OrdinalValue</c> and <c>WeekdayValue</c> for
/// <see cref="MonthTargetKind.OrdinalWeekday"/>. The fields the kind does not use are empty, 0 or null.
/// </summary>
public sealed record MonthTarget(
    MonthTargetKind Kind,
    IReadOnlyList<DayOfMonthSpec> Specs,
    int NearestWeekdayDay = 0,
    NearestDirection? NearestWeekdayDirection = null,
    OrdinalPosition? OrdinalValue = null,
    Weekday? WeekdayValue = null)
{
    public MonthTargetKind Kind { get; } = Kind;

    public IReadOnlyList<DayOfMonthSpec> Specs { get; } = PartList<DayOfMonthSpec>.Of(Specs);

    public int NearestWeekdayDay { get; } = NearestWeekdayDay;

    public NearestDirection? NearestWeekdayDirection { get; } = NearestWeekdayDirection;

    public OrdinalPosition? OrdinalValue { get; } = OrdinalValue;

    public Weekday? WeekdayValue { get; } = WeekdayValue;

    internal static MonthTarget Days(IReadOnlyList<DayOfMonthSpec> specs) =>
        new(MonthTargetKind.Days, specs);

    internal static MonthTarget LastDay() =>
        new(MonthTargetKind.LastDay, []);

    internal static MonthTarget LastWeekday() =>
        new(MonthTargetKind.LastWeekday, []);

    internal static MonthTarget NearestWeekday(int day, NearestDirection? direction = null) =>
        new(MonthTargetKind.NearestWeekday, [], day, direction);

    internal static MonthTarget OrdinalWeekday(OrdinalPosition ordinal, Weekday weekday) =>
        new(MonthTargetKind.OrdinalWeekday, [], OrdinalValue: ordinal, WeekdayValue: weekday);

    internal IReadOnlyList<int> ExpandDays()
    {
        if (Kind != MonthTargetKind.Days)
        {
            return [];
        }

        var days = new List<int>();
        foreach (var spec in Specs)
        {
            days.AddRange(spec.Expand());
        }
        return days;
    }
}

public enum MonthTargetKind
{
    Days,
    LastDay,
    LastWeekday,
    NearestWeekday,
    OrdinalWeekday
}
