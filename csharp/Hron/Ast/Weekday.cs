namespace Hron.Ast;

/// <summary>
/// Represents a day of the week.
/// </summary>
public enum Weekday
{
    Monday = 1,
    Tuesday = 2,
    Wednesday = 3,
    Thursday = 4,
    Friday = 5,
    Saturday = 6,
    Sunday = 7
}

public static class WeekdayExtensions
{
    private static readonly Dictionary<string, Weekday> ParseMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["monday"] = Weekday.Monday,
        ["mon"] = Weekday.Monday,
        ["tuesday"] = Weekday.Tuesday,
        ["tue"] = Weekday.Tuesday,
        ["wednesday"] = Weekday.Wednesday,
        ["wed"] = Weekday.Wednesday,
        ["thursday"] = Weekday.Thursday,
        ["thu"] = Weekday.Thursday,
        ["friday"] = Weekday.Friday,
        ["fri"] = Weekday.Friday,
        ["saturday"] = Weekday.Saturday,
        ["sat"] = Weekday.Saturday,
        ["sunday"] = Weekday.Sunday,
        ["sun"] = Weekday.Sunday
    };

    /// <summary>
    /// Returns the ISO 8601 day number (Monday=1, Sunday=7).
    /// </summary>
    public static int Number(this Weekday weekday) => (int)weekday;

    /// <summary>
    /// Returns the cron day of week number (Sunday=0, Monday=1, ..., Saturday=6).
    /// </summary>
    public static int CronDOW(this Weekday weekday) => weekday switch
    {
        Weekday.Sunday => 0,
        Weekday.Monday => 1,
        Weekday.Tuesday => 2,
        Weekday.Wednesday => 3,
        Weekday.Thursday => 4,
        Weekday.Friday => 5,
        Weekday.Saturday => 6,
        _ => throw new ArgumentOutOfRangeException(nameof(weekday))
    };

    /// <summary>
    /// Returns the lowercase display name.
    /// </summary>
    public static string ToDisplayString(this Weekday weekday) => weekday.ToString().ToLowerInvariant();

    /// <summary>
    /// Parses a weekday name (case insensitive).
    /// </summary>
    public static Weekday? Parse(string s)
        => ParseMap.TryGetValue(s, out var weekday) ? weekday : null;

    /// <summary>
    /// Returns a Weekday from an ISO 8601 day number.
    /// </summary>
    public static Weekday? FromNumber(int n)
        => n is >= 1 and <= 7 ? (Weekday)n : null;

    /// <summary>
    /// Returns a Weekday from a DayOfWeek.
    /// </summary>
    public static Weekday FromDayOfWeek(DayOfWeek dow) => dow switch
    {
        DayOfWeek.Monday => Weekday.Monday,
        DayOfWeek.Tuesday => Weekday.Tuesday,
        DayOfWeek.Wednesday => Weekday.Wednesday,
        DayOfWeek.Thursday => Weekday.Thursday,
        DayOfWeek.Friday => Weekday.Friday,
        DayOfWeek.Saturday => Weekday.Saturday,
        DayOfWeek.Sunday => Weekday.Sunday,
        _ => throw new ArgumentOutOfRangeException(nameof(dow))
    };

    /// <summary>
    /// Converts this Weekday to a DayOfWeek.
    /// </summary>
    public static DayOfWeek ToDayOfWeek(this Weekday weekday) => weekday switch
    {
        Weekday.Monday => DayOfWeek.Monday,
        Weekday.Tuesday => DayOfWeek.Tuesday,
        Weekday.Wednesday => DayOfWeek.Wednesday,
        Weekday.Thursday => DayOfWeek.Thursday,
        Weekday.Friday => DayOfWeek.Friday,
        Weekday.Saturday => DayOfWeek.Saturday,
        Weekday.Sunday => DayOfWeek.Sunday,
        _ => throw new ArgumentOutOfRangeException(nameof(weekday))
    };
}
