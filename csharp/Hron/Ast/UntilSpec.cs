namespace Hron.Ast;

internal sealed record UntilSpec(UntilSpecKind Kind, string? Date, MonthName? Month, int Day)
{
    public static UntilSpec Iso(string date)
        => new(UntilSpecKind.Iso, date, null, 0);

    public static UntilSpec Named(MonthName month, int day)
        => new(UntilSpecKind.Named, null, month, day);
}

internal enum UntilSpecKind
{
    Iso,
    Named
}
