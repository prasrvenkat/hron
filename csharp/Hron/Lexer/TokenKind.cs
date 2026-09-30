namespace Hron.Lexer;

/// <summary>
/// The type of token.
/// </summary>
public enum TokenKind
{
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
    Nearest,
    Next,
    Previous,

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
