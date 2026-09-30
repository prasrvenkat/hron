using System.Globalization;
using Xunit;

namespace Hron.Tests;

public class CultureTest
{
    [Theory]
    [InlineData("th-TH")]
    [InlineData("ar-SA")]
    public void IsoDatesIgnoreTheCurrentCulture(string culture)
    {
        const string expression = "every 2 days at 09:00 except 2026-03-03 until 2026-03-09 starting 2026-03-01 in UTC";
        var original = CultureInfo.CurrentCulture;
        CultureInfo.CurrentCulture = new CultureInfo(culture);
        try
        {
            var schedule = Schedule.Parse(expression);
            var now = new DateTimeOffset(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);

            DateTimeOffset[] expected =
            [
                new(2026, 3, 1, 9, 0, 0, TimeSpan.Zero),
                new(2026, 3, 5, 9, 0, 0, TimeSpan.Zero),
                new(2026, 3, 7, 9, 0, 0, TimeSpan.Zero),
                new(2026, 3, 9, 9, 0, 0, TimeSpan.Zero),
            ];
            Assert.Equal(expected, schedule.NextNFrom(now, 10));
            Assert.Equal(new DateTimeOffset(2026, 3, 15, 9, 0, 0, TimeSpan.Zero), Schedule.Parse("on 2026-03-15 at 09:00").NextFrom(now));
            Assert.Equal(expression, schedule.ToString());
        }
        finally
        {
            CultureInfo.CurrentCulture = original;
        }
    }
}
