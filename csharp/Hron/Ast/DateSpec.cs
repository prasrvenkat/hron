namespace Hron.Ast;

internal sealed record DateSpec(DateSpecKind Kind, MonthName? Month, int Day, string? Date)
{
    public static DateSpec Named(MonthName month, int day)
        => new(DateSpecKind.Named, month, day, null);

    public static DateSpec Iso(string date)
        => new(DateSpecKind.Iso, null, 0, date);
}

internal enum DateSpecKind
{
    Named,
    Iso
}
