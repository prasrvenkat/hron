namespace Hron.Ast;

/// <summary>
/// Represents an ordinal position (first, second, etc.).
/// </summary>
public enum OrdinalPosition
{
    First = 1,
    Second = 2,
    Third = 3,
    Fourth = 4,
    Fifth = 5,
    Last = -1
}

public static class OrdinalPositionExtensions
{
    private static readonly Dictionary<string, OrdinalPosition> ParseMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["first"] = OrdinalPosition.First,
        ["second"] = OrdinalPosition.Second,
        ["third"] = OrdinalPosition.Third,
        ["fourth"] = OrdinalPosition.Fourth,
        ["fifth"] = OrdinalPosition.Fifth,
        ["last"] = OrdinalPosition.Last
    };

    /// <summary>
    /// Returns the ordinal as a number (1-5, or -1 for Last).
    /// </summary>
    public static int ToN(this OrdinalPosition ordinal) => (int)ordinal;

    /// <summary>
    /// Returns the lowercase display name.
    /// </summary>
    public static string ToDisplayString(this OrdinalPosition ordinal) => ordinal switch
    {
        OrdinalPosition.First => "first",
        OrdinalPosition.Second => "second",
        OrdinalPosition.Third => "third",
        OrdinalPosition.Fourth => "fourth",
        OrdinalPosition.Fifth => "fifth",
        OrdinalPosition.Last => "last",
        _ => throw new ArgumentOutOfRangeException(nameof(ordinal))
    };

    /// <summary>
    /// Parses an ordinal position name (case insensitive).
    /// </summary>
    public static OrdinalPosition? Parse(string s)
        => ParseMap.TryGetValue(s, out var ordinal) ? ordinal : null;
}
