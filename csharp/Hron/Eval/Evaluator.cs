using Hron.Ast;
using static Hron.Eval.SupportedRange;

namespace Hron.Eval;

internal static class Evaluator
{
    public static DateTimeOffset? NextFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        return Nearest(data, now, location, Direction.Forward);
    }

    public static IReadOnlyList<DateTimeOffset> NextNFrom(ScheduleData data, DateTimeOffset now, int n, TimeZoneInfo location)
    {
        return Occurrences(data, now, location).Take(n).ToList();
    }

    public static IEnumerable<DateTimeOffset> Occurrences(ScheduleData data, DateTimeOffset from, TimeZoneInfo location)
    {
        if (!InSupportedRange(from))
        {
            yield break;
        }
        var search = Search.Of(data, location);
        for (var next = search.Nearest(from, Direction.Forward); next is { } current; next = search.Nearest(current, Direction.Forward))
        {
            yield return current;
        }
    }

    public static IEnumerable<DateTimeOffset> Between(ScheduleData data, DateTimeOffset from, DateTimeOffset to, TimeZoneInfo location)
    {
        return InSupportedRange(to) ? Occurrences(data, from, location).TakeWhile(t => t <= to) : [];
    }

    public static DateTimeOffset? PreviousFrom(ScheduleData data, DateTimeOffset now, TimeZoneInfo location)
    {
        return Nearest(data, now, location, Direction.Backward);
    }

    /// <remarks>
    /// Defined through the forward search, so the two can never disagree about what an occurrence
    /// is (spec/README.md, "matches is true exactly when the minute containing t is an
    /// occurrence").
    /// </remarks>
    public static bool Matches(ScheduleData data, DateTimeOffset dt, TimeZoneInfo location)
    {
        if (!InSupportedRange(dt))
        {
            return false;
        }
        var wall = TimeZoneInfo.ConvertTime(dt, location).DateTime;
        var minute = dt.AddTicks(-(wall.Ticks % TimeSpan.TicksPerMinute));
        var justBefore = minute.AddTicks(-1);
        // An occurrence never lands before the date it is scheduled on, so one at this minute is
        // scheduled on or before the minute's wall date.
        var search = Search.Of(data, location);
        search.EndOn(DateOnly.FromDateTime(wall));
        return search.Nearest(justBefore, Direction.Forward) == minute;
    }

    private static DateTimeOffset? Nearest(ScheduleData data, DateTimeOffset now, TimeZoneInfo location, Direction direction)
    {
        return InSupportedRange(now) ? Search.Of(data, location).Nearest(now, direction) : null;
    }
}
