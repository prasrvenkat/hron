namespace Hron.Ast;

/// <param name="Hour">The hour (0-23)</param>
/// <param name="Minute">The minute (0-59)</param>
public readonly record struct TimeOfDay(int Hour, int Minute)
{
    public int TotalMinutes => Hour * 60 + Minute;

    public override string ToString() => $"{Hour:D2}:{Minute:D2}";
}
