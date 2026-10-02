namespace Hron.Ast;

internal enum MonthName
{
    January = 1,
    February = 2,
    March = 3,
    April = 4,
    May = 5,
    June = 6,
    July = 7,
    August = 8,
    September = 9,
    October = 10,
    November = 11,
    December = 12
}

internal static class MonthNameExtensions
{
    private static readonly Dictionary<string, MonthName> ParseMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["january"] = MonthName.January,
        ["jan"] = MonthName.January,
        ["february"] = MonthName.February,
        ["feb"] = MonthName.February,
        ["march"] = MonthName.March,
        ["mar"] = MonthName.March,
        ["april"] = MonthName.April,
        ["apr"] = MonthName.April,
        ["may"] = MonthName.May,
        ["june"] = MonthName.June,
        ["jun"] = MonthName.June,
        ["july"] = MonthName.July,
        ["jul"] = MonthName.July,
        ["august"] = MonthName.August,
        ["aug"] = MonthName.August,
        ["september"] = MonthName.September,
        ["sep"] = MonthName.September,
        ["october"] = MonthName.October,
        ["oct"] = MonthName.October,
        ["november"] = MonthName.November,
        ["nov"] = MonthName.November,
        ["december"] = MonthName.December,
        ["dec"] = MonthName.December
    };

    private static readonly string[] DisplayNames =
    [
        "", "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ];

    public static int Number(this MonthName month) => (int)month;

    public static string ToDisplayString(this MonthName month) => DisplayNames[(int)month];

    public static MonthName? Parse(string s)
        => ParseMap.TryGetValue(s, out var month) ? month : null;
}
