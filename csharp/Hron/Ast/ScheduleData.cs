namespace Hron.Ast;

/// <summary>
/// Represents the complete parsed schedule with all clauses.
/// </summary>
/// <param name="Expr">The schedule expression</param>
/// <param name="Timezone">The IANA timezone (may be null)</param>
/// <param name="Except">The exception dates</param>
/// <param name="Until">The until date (may be null)</param>
/// <param name="Anchor">The anchor date for interval alignment (ISO string, may be null)</param>
/// <param name="During">The months during which the schedule applies</param>
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
