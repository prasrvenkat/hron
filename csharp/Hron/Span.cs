namespace Hron;

/// <summary>
/// Represents a range of character positions in the input.
/// </summary>
/// <param name="Start">The start position (inclusive)</param>
/// <param name="End">The end position (exclusive)</param>
public readonly record struct Span(int Start, int End)
{
    /// <summary>
    /// Returns the length of this span.
    /// </summary>
    public int Length => Math.Max(1, End - Start);
}
