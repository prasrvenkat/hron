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
    public static string ToValue(this ErrorKind kind) => kind switch
    {
        ErrorKind.Lex => "lex",
        ErrorKind.Parse => "parse",
        ErrorKind.Eval => "eval",
        ErrorKind.Cron => "cron",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
