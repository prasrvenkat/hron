namespace Hron.Lexer;

/// <summary>
/// The type of token.
/// </summary>
public enum TokenKind
{
    // Keywords
    Every,
    On,
    At,
    From,
    To,
    In,
    Of,
    The,
    Last,
    Except,
    Until,
    Starting,
    During,
    Year,
    Day,
    Weekday,
    Weekend,
    Weeks,
    Month,

    // Value-carrying tokens
    DayName,
    MonthName,
    Ordinal,
    IntervalUnit,
    Number,
    OrdinalNumber,
    Time,
    IsoDate,
    Comma,
    Timezone
}
