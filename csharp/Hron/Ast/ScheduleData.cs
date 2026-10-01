namespace Hron.Ast;

/// <param name="Timezone">The IANA timezone name, or null for UTC</param>
/// <param name="Anchor">The <c>starting</c> date as an ISO string, or null</param>
public sealed record ScheduleData(
    IScheduleExpr Expr,
    string? Timezone,
    IReadOnlyList<ExceptionSpec> Except,
    UntilSpec? Until,
    string? Anchor,
    IReadOnlyList<MonthName> During)
{
    public static ScheduleData Of(IScheduleExpr expr)
        => new(expr, null, [], null, null, []);

    public ScheduleData WithTimezone(string? timezone)
        => new(Expr, timezone, Except, Until, Anchor, During);

    public ScheduleData WithExcept(IReadOnlyList<ExceptionSpec> except)
        => new(Expr, Timezone, except, Until, Anchor, During);

    public ScheduleData WithUntil(UntilSpec? until)
        => new(Expr, Timezone, Except, until, Anchor, During);

    public ScheduleData WithAnchor(string? anchor)
        => new(Expr, Timezone, Except, Until, anchor, During);

    public ScheduleData WithDuring(IReadOnlyList<MonthName> during)
        => new(Expr, Timezone, Except, Until, Anchor, during);
}
