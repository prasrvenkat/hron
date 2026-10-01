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

    /// <summary>
    /// Whether <paramref name="a"/> comes before <paramref name="b"/> in this direction.
    /// </summary>
    public static bool Precedes<T>(this Direction direction, T a, T b) where T : IComparable<T> => direction switch
    {
        Direction.Forward => a.CompareTo(b) < 0,
        _ => a.CompareTo(b) > 0
    };
}
