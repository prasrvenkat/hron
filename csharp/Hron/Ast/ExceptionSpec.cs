namespace Hron.Ast;

internal sealed record ExceptionSpec(ExceptionSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    public static ExceptionSpec Named(MonthName month, int day)
        => new(ExceptionSpecKind.Named, month, day, null);

    public static ExceptionSpec Iso(string date)
        => new(ExceptionSpecKind.Iso, null, 0, date);
}

internal enum ExceptionSpecKind
{
    Named,
    Iso
}
