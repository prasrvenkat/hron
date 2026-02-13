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

    /// <summary>
    /// Creates a new lexer error.
    /// </summary>
    public static HronException Lex(string message, Span span, string input)
        => new(ErrorKind.Lex, message, span, input, null);

    /// <summary>
    /// Creates a new parser error.
    /// </summary>
    public static HronException Parse(string message, Span span, string input, string? suggestion = null)
        => new(ErrorKind.Parse, message, span, input, suggestion);

    /// <summary>
    /// Creates a new evaluation error.
    /// </summary>
    public static HronException Eval(string message)
        => new(ErrorKind.Eval, message, null, null, null);

    /// <summary>
    /// Creates a new cron conversion error.
    /// </summary>
    public static HronException Cron(string message)
        => new(ErrorKind.Cron, message, null, null, null);

    /// <summary>
    /// The kind of error.
    /// </summary>
    public ErrorKind Kind { get; }

    /// <summary>
    /// The span where the error occurred, if available.
    /// </summary>
    public Span? Span { get; }

    /// <summary>
    /// The original input string, if available.
    /// </summary>
    public string? Input { get; }

    /// <summary>
    /// A suggestion for fixing the error, if available.
    /// </summary>
    public string? Suggestion { get; }

    /// <summary>
    /// Formats a rich error message with underline and optional suggestion.
    /// </summary>
    public string DisplayRich()
    {
        if ((Kind == ErrorKind.Lex || Kind == ErrorKind.Parse) && Span.HasValue && Input is not null)
        {
            var span = Span.Value;
            var sb = new System.Text.StringBuilder();
            sb.Append("error: ").AppendLine(Message);
            sb.Append("  ").AppendLine(Input);

            sb.Append(new string(' ', span.Start + 2));
            sb.Append(new string('^', span.Length));

            if (!string.IsNullOrEmpty(Suggestion))
            {
                sb.Append(" try: \"").Append(Suggestion).Append('"');
            }

            return sb.ToString();
        }

        return $"error: {Message}";
    }
}
