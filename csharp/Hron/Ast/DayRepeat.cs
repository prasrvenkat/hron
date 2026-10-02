namespace Hron.Ast;

public sealed record DayRepeat(int Interval, DayFilter Days, IReadOnlyList<TimeOfDay> Times) : IScheduleExpr
{
    public int Interval { get; } = Interval;

    public DayFilter Days { get; } = Days;

    public IReadOnlyList<TimeOfDay> Times { get; } = PartList<TimeOfDay>.Of(Times);
}
