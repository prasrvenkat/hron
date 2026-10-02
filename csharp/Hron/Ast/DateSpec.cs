namespace Hron.Ast;

/// <summary>
/// A <see cref="DateSpecKind.Named"/> date is <c>Month</c> and <c>Day</c>; an <see cref="DateSpecKind.Iso"/>
/// date is <c>Date</c>, written <c>YYYY-MM-DD</c>. The fields the kind does not use are null or 0.
/// </summary>
public sealed record DateSpec(DateSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    public DateSpecKind Kind { get; } = Kind;

    public MonthName? Month { get; } = Month;

    public int Day { get; } = Day;

    public string? Date { get; } = Date;

    internal static DateSpec Named(MonthName month, int day)
        => new(DateSpecKind.Named, month, day, null);

    internal static DateSpec Iso(string date)
        => new(DateSpecKind.Iso, null, 0, date);
}

public enum DateSpecKind
{
    Named,
    Iso
}
