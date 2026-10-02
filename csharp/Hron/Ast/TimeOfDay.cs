namespace Hron.Ast;

internal readonly record struct TimeOfDay(int Hour, int Minute)
{
    public int TotalMinutes => Hour * 60 + Minute;

    public override string ToString() => $"{Hour:D2}:{Minute:D2}";
}
