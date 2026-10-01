using Hron.Ast;

namespace Hron.Lexer;

/// <param name="Span">UTF-16 offsets into the input; errors convert them to code points.</param>
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
    public static Token Keyword(TokenKind kind, Span span)
        => new(kind, span);

    public static Token DayName(Weekday day, Span span)
        => new(TokenKind.DayName, span, DayNameVal: day);

    public static Token MonthName(MonthName month, Span span)
        => new(TokenKind.MonthName, span, MonthNameVal: month);

    public static Token Ordinal(OrdinalPosition ord, Span span)
        => new(TokenKind.Ordinal, span, OrdinalVal: ord);

    public static Token IntervalUnit(IntervalUnit unit, Span span)
        => new(TokenKind.IntervalUnit, span, UnitVal: unit);

    public static Token Number(int value, Span span)
        => new(TokenKind.Number, span, NumberVal: value);

    public static Token OrdinalNumber(int value, Span span)
        => new(TokenKind.OrdinalNumber, span, NumberVal: value);

    public static Token Time(int hour, int minute, Span span)
        => new(TokenKind.Time, span, TimeHour: hour, TimeMinute: minute);

    public static Token IsoDate(string date, Span span)
        => new(TokenKind.IsoDate, span, IsoDateVal: date);

    public static Token Comma(Span span)
        => new(TokenKind.Comma, span);

    public static Token Timezone(string tz, Span span)
        => new(TokenKind.Timezone, span, TimezoneVal: tz);
}
