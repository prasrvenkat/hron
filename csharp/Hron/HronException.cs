namespace Hron;

/// <summary>
/// Exception thrown for errors in hron parsing, evaluation, or cron conversion.
/// </summary>
public sealed class HronException : Exception
{
    private HronException(ErrorKind kind, string message, Span? span, string? input, string? suggestion)
        : base(message)
    {
        Kind = kind;
        Span = span;
        Input = input;
        Suggestion = suggestion;
    }

    public static HronException Lex(string message, Span span, string input)
        => new(ErrorKind.Lex, message, span, input, null);

    public static HronException Parse(string message, Span span, string input, string? suggestion = null)
        => new(ErrorKind.Parse, message, span, input, suggestion);

    public static HronException Eval(string message)
        => new(ErrorKind.Eval, message, null, null, null);

    public static HronException Cron(string message)
        => new(ErrorKind.Cron, message, null, null, null);

    public ErrorKind Kind { get; }

    /// <summary>
    /// The part of <see cref="Input"/> the error points at, in code points. Null unless this is a
    /// lex or parse error.
    /// </summary>
    public Span? Span { get; }

    /// <summary>
    /// Null unless this is a lex or parse error.
    /// </summary>
    public string? Input { get; }

    /// <summary>
    /// Text to put in place of the span. Null unless the parser has a fix to suggest.
    /// </summary>
    public string? Suggestion { get; }

    /// <summary>
    /// The message, then for a lex or parse error the input and a line of carets under the span,
    /// with any suggestion as <c> try: "..."</c>. Lines are joined by <c>\n</c>, with no trailing newline.
    /// </summary>
    public string DisplayRich()
    {
        if (Span is not { } span || Input is null)
        {
            return $"error: {Message}";
        }

        // A tab, CR or LF would move the input off the line the carets are aligned to.
        var shown = Input.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
        var rich = $"error: {Message}\n  {shown}\n  {new string(' ', span.Start)}{new string('^', span.Length)}";
        return Suggestion is null ? rich : $"{rich} try: \"{Suggestion}\"";
    }
}
