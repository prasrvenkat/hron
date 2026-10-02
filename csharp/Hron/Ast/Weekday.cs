namespace Hron.Ast;

internal enum Weekday
{
    Monday = 1,
    Tuesday = 2,
    Wednesday = 3,
    Thursday = 4,
    Friday = 5,
    Saturday = 6,
    Sunday = 7
}

internal static class WeekdayExtensions
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

    public static int Number(this Weekday weekday) => (int)weekday;

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

    public static string ToDisplayString(this Weekday weekday) => weekday.ToString().ToLowerInvariant();

    public static Weekday? Parse(string s)
        => ParseMap.TryGetValue(s, out var weekday) ? weekday : null;

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
