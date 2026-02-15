using Xunit;

namespace Hron.Tests;

/// <summary>
/// Iterator-specific tests for <c>Occurrences()</c> and <c>Between()</c> methods.
///
/// These tests verify C#-specific IEnumerable behavior beyond conformance tests:
/// - Laziness (IEnumerables don't evaluate eagerly)
/// - Early termination
/// - Integration with LINQ methods
/// - foreach patterns
/// </summary>
public class IteratorTest
{
    private static DateTimeOffset ParseZoned(string s)
    {
        // Parse '2026-02-06T12:00:00+00:00[UTC]' format
        var bracketIdx = s.IndexOf('[');
        var isoStr = s.Substring(0, bracketIdx);
        var tzName = s.Substring(bracketIdx + 1, s.Length - bracketIdx - 2);
        var dto = DateTimeOffset.Parse(isoStr);
        // Convert to the target timezone
        var tz = TimeZoneInfo.FindSystemTimeZoneById(tzName);
        return TimeZoneInfo.ConvertTime(dto, tz);
    }

    // =========================================================================
    // Laziness Tests
    // =========================================================================

    [Fact]
    public void OccurrencesIsLazy()
    {
        // An unbounded schedule should not hang or OOM when creating the enumerable
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Creating the enumerable should be instant (lazy)
        var iter = schedule.Occurrences(from);

        // Taking just 1 should work without evaluating the rest
        var results = iter.Take(1).ToList();
        Assert.Single(results);
    }

    [Fact]
    public void BetweenIsLazy()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");
        var to = ParseZoned("2026-12-31T23:59:00+00:00[UTC]");

        // Creating the enumerable should be instant
        var iter = schedule.Between(from, to);

        // Taking just 3 should not evaluate all ~330 days
        var results = iter.Take(3).ToList();
        Assert.Equal(3, results.Count);
    }

    // =========================================================================
    // Early Termination Tests
    // =========================================================================

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

        // Find the first Saturday occurrence
        var saturday = schedule.Occurrences(from)
            .First(dt => dt.DayOfWeek == DayOfWeek.Saturday);

        // Feb 7, 2026 is a Saturday
        Assert.Equal(7, saturday.Day);
    }

    // =========================================================================
    // LINQ Methods Tests
    // =========================================================================

    [Fact]
    public void WorksWithWhere()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Filter to only weekends from first 14 days
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

        // Map to just the day number
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

        // Skip first 5, take next 3
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

        // Count occurrences in range
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

    // =========================================================================
    // Collect Patterns
    // =========================================================================

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

    // =========================================================================
    // foreach Patterns
    // =========================================================================

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

    // =========================================================================
    // Edge Cases
    // =========================================================================

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

    // =========================================================================
    // Timezone Handling
    // =========================================================================

    [Fact]
    public void OccurrencesPreservesTimezone()
    {
        var schedule = Schedule.Parse("every day at 09:00 in America/New_York");
        var from = ParseZoned("2026-02-01T00:00:00-05:00[America/New_York]");

        var results = schedule.Occurrences(from).Take(3).ToList();

        foreach (var dt in results)
        {
            // Check that offset is either -5 or -4 (EST or EDT)
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

    // =========================================================================
    // Multiple Times Per Day
    // =========================================================================

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

    // =========================================================================
    // Complex LINQ Chains
    // =========================================================================

    [Fact]
    public void ComplexLinqChain()
    {
        var schedule = Schedule.Parse("every day at 09:00 in UTC");
        var from = ParseZoned("2026-02-01T00:00:00+00:00[UTC]");

        // Complex chain: skip weekends, take first 5 weekdays, get their day numbers
        var weekdayDays = schedule.Occurrences(from)
            .Take(14) // Two weeks to ensure we have enough
            .Where(dt => dt.DayOfWeek >= DayOfWeek.Monday && dt.DayOfWeek <= DayOfWeek.Friday)
            .Take(5)
            .Select(dt => dt.Day)
            .ToList();

        // Feb 2026: 2,3,4,5,6 are Mon-Fri
        Assert.Equal(new[] { 2, 3, 4, 5, 6 }, weekdayDays);
    }

    // =========================================================================
    // IEnumerable Properties
    // =========================================================================

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

        // First enumeration
        var first = iter.Count();
        // Second enumeration
        var second = iter.Count();

        Assert.Equal(5, first);
        Assert.Equal(5, second);
    }
}
