namespace Hron.Ast;

/// <summary>
/// A <see cref="ExceptionSpecKind.Named"/> exception is <c>Month</c> and <c>Day</c>, every year; an
/// <see cref="ExceptionSpecKind.Iso"/> one is <c>Date</c>, written <c>YYYY-MM-DD</c>. The fields the
/// kind does not use are null or 0.
/// </summary>
public sealed record ExceptionSpec(ExceptionSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    public ExceptionSpecKind Kind { get; } = Kind;

    public MonthName? Month { get; } = Month;

    public int Day { get; } = Day;

    public string? Date { get; } = Date;

    internal static ExceptionSpec Named(MonthName month, int day)
        => new(ExceptionSpecKind.Named, month, day, null);

    internal static ExceptionSpec Iso(string date)
        => new(ExceptionSpecKind.Iso, null, 0, date);
}

public enum ExceptionSpecKind
{
    Named,
    Iso
}
