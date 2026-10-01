namespace Hron.Eval;

internal enum Direction
{
    Forward,
    Backward
}

internal static class DirectionExtensions
{
    public static int Sign(this Direction direction) => direction switch
    {
        Direction.Forward => 1,
        _ => -1
    };

    public static bool Precedes<T>(this Direction direction, T a, T b) where T : IComparable<T> => direction switch
    {
        Direction.Forward => a.CompareTo(b) < 0,
        _ => a.CompareTo(b) > 0
    };
}
