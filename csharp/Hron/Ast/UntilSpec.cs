namespace Hron.Ast;

/// <summary>
/// An <see cref="UntilSpecKind.Iso"/> until is <c>Date</c>, written <c>YYYY-MM-DD</c>; a
/// <see cref="UntilSpecKind.Named"/> one is <c>Month</c> and <c>Day</c>, the first such date on or
/// after the schedule's <c>starting</c> date. The fields the kind does not use are null or 0.
/// </summary>
public sealed record UntilSpec(UntilSpecKind Kind, string? Date, MonthName? Month, int Day)
{
    public UntilSpecKind Kind { get; } = Kind;

    public string? Date { get; } = Date;

    public MonthName? Month { get; } = Month;

    public int Day { get; } = Day;

    internal static UntilSpec Iso(string date)
        => new(UntilSpecKind.Iso, date, null, 0);

    internal static UntilSpec Named(MonthName month, int day)
        => new(UntilSpecKind.Named, null, month, day);
}

public enum UntilSpecKind
{
    Iso,
    Named
}
