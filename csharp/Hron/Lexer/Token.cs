using Hron.Ast;

namespace Hron.Lexer;

/// <summary>
/// Represents a lexed token.
/// </summary>
public sealed record Token(
    TokenKind Kind,
    Span Span,
    Weekday? DayNameVal = null,
    MonthName? MonthNameVal = null,
    OrdinalPosition? OrdinalVal = null,
    IntervalUnit? UnitVal = null,
    int NumberVal = 0,
    int TimeHour = 0,
    int TimeMinute = 0,
    string? IsoDateVal = null,
    string? TimezoneVal = null)
{
    /// <summary>Creates a simple keyword token.</summary>
    public static Token Keyword(TokenKind kind, Span span)
        => new(kind, span);

    /// <summary>Creates a day name token.</summary>
    public static Token DayName(Weekday day, Span span)
        => new(TokenKind.DayName, span, DayNameVal: day);

    /// <summary>Creates a month name token.</summary>
    public static Token MonthName(MonthName month, Span span)
        => new(TokenKind.MonthName, span, MonthNameVal: month);

    /// <summary>Creates an ordinal token.</summary>
    public static Token Ordinal(OrdinalPosition ord, Span span)
        => new(TokenKind.Ordinal, span, OrdinalVal: ord);

    /// <summary>Creates an interval unit token.</summary>
    public static Token IntervalUnit(IntervalUnit unit, Span span)
        => new(TokenKind.IntervalUnit, span, UnitVal: unit);

    /// <summary>Creates a number token.</summary>
    public static Token Number(int value, Span span)
        => new(TokenKind.Number, span, NumberVal: value);

    /// <summary>Creates an ordinal number token (e.g., "1st", "15th").</summary>
    public static Token OrdinalNumber(int value, Span span)
        => new(TokenKind.OrdinalNumber, span, NumberVal: value);

    /// <summary>Creates a time token.</summary>
    public static Token Time(int hour, int minute, Span span)
        => new(TokenKind.Time, span, TimeHour: hour, TimeMinute: minute);

    /// <summary>Creates an ISO date token.</summary>
    public static Token IsoDate(string date, Span span)
        => new(TokenKind.IsoDate, span, IsoDateVal: date);

    /// <summary>Creates a comma token.</summary>
    public static Token Comma(Span span)
        => new(TokenKind.Comma, span);

    /// <summary>Creates a timezone token.</summary>
    public static Token Timezone(string tz, Span span)
        => new(TokenKind.Timezone, span, TimezoneVal: tz);
}
