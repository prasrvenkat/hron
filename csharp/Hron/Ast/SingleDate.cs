namespace Hron.Ast;

public sealed record SingleDate(DateSpec DateSpec, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr
{
    public DateSpec DateSpec { get; } = DateSpec;

    public IReadOnlyList<TimeOfDay> Times { get; } = PartList<TimeOfDay>.Of(Times);
}
