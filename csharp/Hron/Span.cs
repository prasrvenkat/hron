namespace Hron;

/// <summary>
/// Represents a range of character positions in the input.
/// </summary>
/// <param name="Start">The start position (inclusive)</param>
/// <param name="End">The end position (exclusive)</param>
public readonly record struct Span(int Start, int End)
{
    /// <summary>
    /// <c>End - Start</c>, but at least 1 so an empty span still gets one caret.
    /// </summary>
    public int Length => Math.Max(1, End - Start);
}
