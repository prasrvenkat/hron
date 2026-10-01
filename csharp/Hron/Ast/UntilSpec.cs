namespace Hron.Ast;

public sealed record UntilSpec(UntilSpecKind Kind, string? Date, MonthName? Month, int Day)
{
    public static UntilSpec Iso(string date)
        => new(UntilSpecKind.Iso, date, null, 0);

    public static UntilSpec Named(MonthName month, int day)
        => new(UntilSpecKind.Named, null, month, day);
}

public enum UntilSpecKind
{
    Iso,
    Named
}
