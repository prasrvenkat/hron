namespace Hron;

public enum ErrorKind
{
    Lex,
    Parse,
    Eval,
    Cron
}

public static class ErrorKindExtensions
{
    /// <summary>
    /// The kind as every hron implementation names it: <c>lex</c>, <c>parse</c>, <c>eval</c> or <c>cron</c>.
    /// </summary>
    public static string ToValue(this ErrorKind kind) => kind switch
    {
        ErrorKind.Lex => "lex",
        ErrorKind.Parse => "parse",
        ErrorKind.Eval => "eval",
        ErrorKind.Cron => "cron",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
