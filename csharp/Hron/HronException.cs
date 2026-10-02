namespace Hron;

/// <summary>
/// Exception thrown for errors in hron parsing or cron conversion.
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

    /// <summary>
    /// A lex error at <paramref name="span"/>, in code points, of <paramref name="input"/>.
    /// </summary>
    /// <exception cref="ArgumentNullException">If message or input is null</exception>
    public static HronException Lex(string message, Span span, string input)
    {
        ArgumentNullException.ThrowIfNull(message);
        ArgumentNullException.ThrowIfNull(input);
        return new(ErrorKind.Lex, message, span, input, null);
    }

    /// <summary>
    /// A parse error at <paramref name="span"/>, in code points, of <paramref name="input"/>, with an
    /// optional <paramref name="suggestion"/> to put in place of the span.
    /// </summary>
    /// <exception cref="ArgumentNullException">If message or input is null</exception>
    public static HronException Parse(string message, Span span, string input, string? suggestion = null)
    {
        ArgumentNullException.ThrowIfNull(message);
        ArgumentNullException.ThrowIfNull(input);
        return new(ErrorKind.Parse, message, span, input, suggestion);
    }

    /// <summary>
    /// An eval error, the kind for a schedule built in code from parts that break a rule; this package
    /// never throws one.
    /// </summary>
    /// <exception cref="ArgumentNullException">If message is null</exception>
    public static HronException Eval(string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        return new(ErrorKind.Eval, message, null, null, null);
    }

    /// <summary>
    /// A cron error, the kind <see cref="Schedule.FromCron"/> and <see cref="Schedule.ToCron"/> throw.
    /// </summary>
    /// <exception cref="ArgumentNullException">If message is null</exception>
    public static HronException Cron(string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        return new(ErrorKind.Cron, message, null, null, null);
    }

    /// <summary>
    /// <see cref="ErrorKind.Lex"/> or <see cref="ErrorKind.Parse"/> from <see cref="Schedule.Parse"/>;
    /// <see cref="ErrorKind.Cron"/> from <see cref="Schedule.FromCron"/> and <see cref="Schedule.ToCron"/>.
    /// </summary>
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
