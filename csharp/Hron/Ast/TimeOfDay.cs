namespace Hron.Ast;

public readonly record struct TimeOfDay(int Hour, int Minute)
{
    public int Hour { get; } = Hour;

    public int Minute { get; } = Minute;

    internal int TotalMinutes => Hour * 60 + Minute;

    /// <summary>
    /// The time as <c>HH:MM</c>, as the schedule's <c>ToString</c> writes it.
    /// </summary>
    public override string ToString() => $"{Hour:D2}:{Minute:D2}";
}
