namespace Hron;

/// <summary>
/// A part of the input. <see cref="HronException.Span"/> counts Unicode code points, not UTF-16
/// chars: a surrogate pair is one code point, and so is a lone surrogate.
/// <see cref="Lexer.Token.Span"/> counts UTF-16 chars.
/// </summary>
/// <param name="Start">The start position (inclusive)</param>
/// <param name="End">The end position (exclusive)</param>
public readonly record struct Span(int Start, int End)
{
    /// <summary>
    /// <c>End - Start</c>, but at least 1 so an empty span still gets one caret.
    /// </summary>
    public int Length => Math.Max(1, End - Start);

    internal static Span FromUtf16Range(string input, int start, int end)
    {
        var startCodePoints = CodePoints(input, 0, start);
        return new Span(startCodePoints, startCodePoints + CodePoints(input, start, end));
    }

    private static int CodePoints(string input, int from, int to)
    {
        var count = 0;
        for (var i = from; i < to; i++)
        {
            if (char.IsHighSurrogate(input[i]) && i + 1 < to && char.IsLowSurrogate(input[i + 1]))
            {
                i++;
            }
            count++;
        }
        return count;
    }
}
