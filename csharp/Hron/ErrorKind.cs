namespace Hron;

/// <summary>
/// The type of error that occurred during parsing, evaluation, or conversion.
/// </summary>
public enum ErrorKind
{
    /// <summary>Lexer error - invalid tokens in input.</summary>
    Lex,
    /// <summary>Parser error - invalid syntax.</summary>
    Parse,
    /// <summary>Evaluation error - cannot compute next occurrence.</summary>
    Eval,
    /// <summary>Cron conversion error - expression not convertible to cron.</summary>
    Cron
}

public static class ErrorKindExtensions
{
    public static string ToValue(this ErrorKind kind) => kind switch
    {
        ErrorKind.Lex => "lex",
        ErrorKind.Parse => "parse",
        ErrorKind.Eval => "eval",
        ErrorKind.Cron => "cron",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
