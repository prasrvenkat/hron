using System.Globalization;

namespace Hron;

internal static class IsoDate
{
    public static bool TryParse(string text, out DateOnly date)
        => DateOnly.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date);

    public static DateOnly Parse(string text)
        => DateOnly.ParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture);
}
