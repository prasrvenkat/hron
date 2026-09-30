using Xunit;

namespace Hron.Tests;

/// <summary>
/// IEnumerable behaviour of <c>Occurrences()</c> and <c>Between()</c> that the conformance suite
/// cannot check: laziness, early termination and composition with LINQ.
/// </summary>
public class IteratorTest
{
    private static DateTimeOffset ParseZoned(string s)
    {
        var bracketIdx = s.IndexOf('[');
        var isoStr = s.Substring(0, bracketIdx);
        var tzName = s.Substring(bracketIdx + 1, s.Length - bracketIdx - 2);
        var dto = DateTimeOffset.Parse(isoStr);
        var tz = TimeZoneInfo.FindSystemTimeZoneById(tzName);
        return TimeZoneInfo.ConvertTime(dto, tz);
    }

    [Fact]
    public void OccurrencesIsLazy()
    {
        // An unbounded schedule should not hang or OOM when creating the enumerable
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var iter = schedule.Occurrences(from);

        var results = iter.Take(1).ToList();
        Assert.Single(results);
    }

    [Fact]
    public void BetweenIsLazy()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-12-31T23:59:00+00:00[UTC]");

        var iter = schedule.Between(from, to);

        // Taking just 3 should not evaluate all ~330 days
        var results = iter.Take(3).ToList();
        Assert.Equal(3, results.Count);
    }

    [Fact]
    public void OccurrencesEarlyTerminationWithTake()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from).Take(5).ToList();

        Assert.Equal(5, results.Count);
    }

    [Fact]
    public void OccurrencesEarlyTerminationWithTakeWhile()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var cutoff = ParseZoned("2026-02-05T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from)
            .TakeWhile(dt => dt < cutoff)
            .ToList();

        // Feb 1, 2, 3, 4 at 09:00 (4 occurrences before Feb 5 00:00)
        Assert.Equal(4, results.Count);
    }

    [Fact]
    public void OccurrencesEarlyTerminationWithBreak()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = new List<DateTimeOffset>();
        foreach (var dt in schedule.Occurrences(from))
        {
            results.Add(dt);
            if (results.Count >= 5) break;
        }

        Assert.Equal(5, results.Count);
    }

    [Fact]
    public void OccurrencesFindFirstSaturday()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var saturday = schedule.Occurrences(from)
            .First(dt => dt.DayOfWeek == DayOfWeek.Saturday);

        // Feb 7, 2026 is a Saturday
        Assert.Equal(7, saturday.Day);
    }

    [Fact]
    public void WorksWithWhere()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var weekends = schedule.Occurrences(from)
            .Take(14)
            .Where(dt => dt.DayOfWeek == DayOfWeek.Saturday || dt.DayOfWeek == DayOfWeek.Sunday)
            .ToList();

        // 2 weekends in 2 weeks = 4 days
        Assert.Equal(4, weekends.Count);
    }

    [Fact]
    public void WorksWithSelect()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var days = schedule.Occurrences(from)
            .Take(5)
            .Select(dt => dt.Day)
            .ToList();

        Assert.Equal(new[] { 1, 2, 3, 4, 5 }, days);
    }

    [Fact]
    public void WorksWithSkip()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from)
            .Skip(5)
            .Take(3)
            .ToList();

        Assert.Equal(3, results.Count);
        // Should be Feb 6, 7, 8
        Assert.Equal(6, results[0].Day);
        Assert.Equal(7, results[1].Day);
        Assert.Equal(8, results[2].Day);
    }

    [Fact]
    public void BetweenWorksWithCount()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-10T23:59:00+00:00[UTC]");

        var count = schedule.Between(from, to).Count();

        // Feb 1-10 inclusive = 10 days
        Assert.Equal(10, count);
    }

    [Fact]
    public void WorksWithLast()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-10T23:59:00+00:00[UTC]");

        var last = schedule.Between(from, to).Last();

        Assert.Equal(10, last.Day);
    }

    [Fact]
    public void OccurrencesCollectToList()
    {
        var schedule = Schedule.Parse("every day at 09:00 until 2026-02-05 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from).ToList();

        Assert.Equal(5, results.Count); // Feb 1-5
    }

    [Fact]
    public void BetweenCollectToList()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-07T23:59:00+00:00[UTC]");

        var results = schedule.Between(from, to).ToList();

        Assert.Equal(7, results.Count);
    }

    [Fact]
    public void CollectToArray()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-05T00:00:00+00:00[UTC]");

        var results = schedule.Between(from, to).ToArray();

        Assert.Equal(4, results.Length);
    }

    [Fact]
    public void OccurrencesForeachWithBreak()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var count = 0;
        foreach (var dt in schedule.Occurrences(from))
        {
            count++;
            if (dt.Day >= 5) break;
        }

        Assert.Equal(5, count);
    }

    [Fact]
    public void BetweenForeach()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-03T23:59:00+00:00[UTC]");

        var days = new List<int>();
        foreach (var dt in schedule.Between(from, to))
        {
            days.Add(dt.Day);
        }

        Assert.Equal(new[] { 1, 2, 3 }, days);
    }

    [Fact]
    public void OccurrencesEmptyWhenPastUntil()
    {
        var schedule = Schedule.Parse("every day at 09:00 until 2026-01-01 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from).Take(10).ToList();

        Assert.Empty(results);
    }

    [Fact]
    public void BetweenEmptyRange()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T12:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-01T13:00:00+00:00[UTC]");

        var results = schedule.Between(from, to).ToList();

        Assert.Empty(results);
    }

    [Fact]
    public void OccurrencesSingleDateTerminates()
    {
        var schedule = Schedule.Parse("on 2026-02-14 at 14:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Request many but should only get 1
        var results = schedule.Occurrences(from).Take(100).ToList();

        Assert.Single(results);
    }

    [Fact]
    public void OccurrencesPreservesTimezone()
    {
        var schedule = Schedule.Parse("every day at 09:00 in America/New_York");
        var from = ParseZoned("2026-02-01T00:00:00-05:00[America/New_York]");

        var results = schedule.Occurrences(from).Take(3).ToList();

        foreach (var dt in results)
        {
            Assert.True(dt.Offset == TimeSpan.FromHours(-5) || dt.Offset == TimeSpan.FromHours(-4));
        }
    }

    [Fact]
    public void BetweenHandlesDSTTransition()
    {
        // March 8, 2026 is DST spring forward in America/New_York
        // 2:00 AM springs forward to 3:00 AM, so 02:30 shifts to 03:30
        var schedule = Schedule.Parse("every day at 02:30 in America/New_York");
        var from = ParseZoned("2026-03-07T00:00:00-05:00[America/New_York]");
        var to = ParseZoned("2026-03-10T00:00:00-04:00[America/New_York]");

        var results = schedule.Between(from, to).ToList();

        // Mar 7 at 02:30, Mar 8 at 03:30 (shifted), Mar 9 at 02:30
        Assert.Equal(3, results.Count);
        Assert.Equal(2, results[0].Hour); // Mar 7 02:30
        Assert.Equal(3, results[1].Hour); // Mar 8 03:30 (shifted due to DST)
        Assert.Equal(2, results[2].Hour); // Mar 9 02:30
    }

    [Fact]
    public void OccurrencesMultipleTimesPerDay()
    {
        var schedule = Schedule.Parse("every day at 09:00, 12:00, 17:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var results = schedule.Occurrences(from).Take(9).ToList(); // 3 days worth

        Assert.Equal(9, results.Count);
        // First day: 09:00, 12:00, 17:00
        Assert.Equal(9, results[0].Hour);
        Assert.Equal(12, results[1].Hour);
        Assert.Equal(17, results[2].Hour);
    }

    [Fact]
    public void ComplexLinqChain()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var weekdayDays = schedule.Occurrences(from)
            .Take(14) // Two weeks to ensure we have enough
            .Where(dt => dt.DayOfWeek >= DayOfWeek.Monday && dt.DayOfWeek <= DayOfWeek.Friday)
            .Take(5)
            .Select(dt => dt.Day)
            .ToList();

        // Feb 2026: 2,3,4,5,6 are Mon-Fri
        Assert.Equal(new[] { 2, 3, 4, 5, 6 }, weekdayDays);
    }

    [Fact]
    public void OccurrencesReturnsIEnumerable()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var iter = schedule.Occurrences(from);

        Assert.IsAssignableFrom<IEnumerable<DateTimeOffset>>(iter);
    }

    [Fact]
    public void BetweenReturnsIEnumerable()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-02-05T00:00:00+00:00[UTC]");

        var iter = schedule.Between(from, to);

        Assert.IsAssignableFrom<IEnumerable<DateTimeOffset>>(iter);
    }

    [Fact]
    public void CanEnumerateMultipleTimes()
    {
        var schedule = Schedule.Parse("every day at 09:00 until 2026-02-05 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        var iter = schedule.Occurrences(from);

        var first = iter.Count();
        var second = iter.Count();

        Assert.Equal(5, first);
        Assert.Equal(5, second);
    }
}
