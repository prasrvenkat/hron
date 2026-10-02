namespace Hron.Ast;

internal sealed record ScheduleData(
    IScheduleExpr Expression,
    string? Timezone,
    IReadOnlyList<ExceptionSpec> Except,
    UntilSpec? Until,
    string? Starting,
    IReadOnlyList<MonthName> During)
{
    public IReadOnlyList<ExceptionSpec> Except { get; } = PartList<ExceptionSpec>.Of(Except);

    public IReadOnlyList<MonthName> During { get; } = PartList<MonthName>.Of(During);

    public static ScheduleData Of(IScheduleExpr expression)
        => new(expression, null, [], null, null, []);

    public ScheduleData WithTimezone(string? timezone)
        => new(Expression, timezone, Except, Until, Starting, During);

    public ScheduleData WithExcept(IReadOnlyList<ExceptionSpec> except)
        => new(Expression, Timezone, except, Until, Starting, During);

    public ScheduleData WithUntil(UntilSpec? until)
        => new(Expression, Timezone, Except, until, Starting, During);

    public ScheduleData WithStarting(string? starting)
        => new(Expression, Timezone, Except, Until, starting, During);

    public ScheduleData WithDuring(IReadOnlyList<MonthName> during)
        => new(Expression, Timezone, Except, Until, Starting, during);
}
