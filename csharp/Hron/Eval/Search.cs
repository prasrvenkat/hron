using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// A schedule prepared for searching: its zone, cadence, times and clauses resolved once.
/// </summary>
internal sealed class Search
{
    private readonly IScheduleExpr _expr;
    private readonly TimeZoneInfo _zone;
    private readonly Cadence _cadence;
    private readonly DailyTimes _times;
    private readonly Clauses _clauses;

    private Search(IScheduleExpr expr, TimeZoneInfo zone, Cadence cadence, DailyTimes times, Clauses clauses)
    {
        _expr = expr;
        _zone = zone;
        _cadence = cadence;
        _times = times;
        _clauses = clauses;
    }

    public static Search Of(ScheduleData data, TimeZoneInfo zone)
    {
        DateOnly? starting = data.Anchor is null ? null : IsoDate.Parse(data.Anchor);
        return new Search(
            data.Expr,
            zone,
            Cadence.Of(data.Expr, starting),
            DailyTimes.Of(data.Expr),
            Clauses.Of(data, starting));
    }

    /// <summary>
    /// This search with nothing scheduled after <paramref name="date"/>, as an until would end it.
    /// </summary>
    public Search EndingOn(DateOnly date)
    {
        return new Search(_expr, _zone, _cadence, _times, _clauses.EndingOn(date));
    }

    /// <summary>
    /// The occurrence nearest <paramref name="now"/> strictly beyond it in
    /// <paramref name="direction"/>.
    /// </summary>
    public DateTimeOffset? Nearest(DateTimeOffset now, Direction direction)
    {
        var firstDate = _clauses.Clamp(WallClock.LocalDate(now, _zone), direction);
        // A nearest weekday or a DST shift can move an occurrence out of the period it is
        // scheduled in, so the search starts one period back.
        var firstPeriod = _cadence.PeriodOf(firstDate) - direction.Sign();
        var reach = _clauses.FarthestExceptDate(direction) is { } except ? _cadence.PeriodOf(except) : firstPeriod;
        Occurrence? best = null;
        foreach (var period in _cadence.Periods(firstPeriod, reach, direction))
        {
            foreach (var candidate in InOrder(CandidatesInPeriod(period), direction))
            {
                var beaten = best is { } found && !Occurrence.CouldBeat(candidate.Date, found, direction);
                if (beaten || _clauses.EndsSearch(candidate.Date, direction))
                {
                    return best?.Instant;
                }
                if (!_clauses.Allows(candidate))
                {
                    continue;
                }
                if (NearestOnDate(candidate.Date, now, direction) is { } instant &&
                    (best is not { } current || direction.Precedes(instant, current.Instant)))
                {
                    best = new Occurrence(instant, candidate.Date);
                }
            }
        }
        return best?.Instant;
    }

    /// <summary>
    /// The occurrence on <paramref name="date"/> nearest <paramref name="now"/> strictly beyond it
    /// in <paramref name="direction"/>.
    /// </summary>
    private DateTimeOffset? NearestOnDate(DateOnly date, DateTimeOffset now, Direction direction) => _times switch
    {
        DailyTimes.Fixed fixedTimes => NearestFixedTime(fixedTimes.Times, date, now, direction),
        DailyTimes.Slots slots => NearestSlot(slots, date, now, direction),
        _ => null
    };

    /// <summary>
    /// Every time is resolved, since a time shifted out of a gap can land after a later wall time.
    /// </summary>
    private DateTimeOffset? NearestFixedTime(IReadOnlyList<TimeOfDay> times, DateOnly date, DateTimeOffset now, Direction direction)
    {
        DateTimeOffset? nearest = null;
        foreach (var time in times)
        {
            if (WallClock.FixedTimeOn(date, time, _zone) is { } instant && direction.Precedes(now, instant) &&
                (nearest is not { } current || direction.Precedes(instant, current)))
            {
                nearest = instant;
            }
        }
        return nearest;
    }

    /// <summary>
    /// Slots resolve in wall-clock order, so the first beyond <paramref name="now"/> is the
    /// nearest.
    /// </summary>
    private DateTimeOffset? NearestSlot(DailyTimes.Slots slots, DateOnly date, DateTimeOffset now, Direction direction)
    {
        var (earliest, latest) = WallMinutesWorthResolving(date, now, direction);
        foreach (var minute in slots.Within(earliest, latest, direction))
        {
            if (WallClock.SlotOn(date, minute, _zone) is { } instant && direction.Precedes(now, instant))
            {
                return instant;
            }
        }
        return null;
    }

    /// <summary>
    /// The wall-clock minutes of <paramref name="date"/> that can hold an occurrence beyond
    /// <paramref name="now"/>. A wall time w fires at w − o for one of the date's offsets o, so it
    /// is after now only if w &gt; now + min(o) and before now only if w &lt; now + max(o);
    /// resolving the other slots, the costly part, is skipped.
    /// </summary>
    private (long Earliest, long Latest) WallMinutesWorthResolving(DateOnly date, DateTimeOffset now, Direction direction)
    {
        var midnight = date.ToDateTime(TimeOnly.MinValue).Ticks;
        var before = WallClock.OffsetAt(midnight - TimeSpan.TicksPerDay, _zone).Ticks;
        var after = WallClock.OffsetAt(midnight + 2 * TimeSpan.TicksPerDay, _zone).Ticks;
        var sinceMidnight = now.UtcTicks - midnight;
        return direction == Direction.Forward
            ? (Calendar.FloorDiv(sinceMidnight + Math.Min(before, after), TimeSpan.TicksPerMinute), long.MaxValue)
            : (long.MinValue, -Calendar.FloorDiv(-(sinceMidnight + Math.Max(before, after)), TimeSpan.TicksPerMinute));
    }

    /// <summary>
    /// The candidates in <paramref name="period"/>, earliest first.
    /// </summary>
    private IReadOnlyList<Candidate> CandidatesInPeriod(long period)
    {
        if (_expr is MonthRepeat mr)
        {
            var month = _cadence.MonthIndexOf(period);
            var targetMonth = (int)Calendar.FloorMod(month, 12) + 1;
            // Every date in the period has this target month, so a month `during` rejects need
            // not be resolved.
            if (!_clauses.AllowsTargetMonth(targetMonth))
            {
                return [];
            }
            return Calendar.MonthTargetDates(month, mr.Target).Select(date => new Candidate(date, targetMonth)).ToArray();
        }
        if (_cadence.StartOf(period) is not { } start)
        {
            return [];
        }
        return DatesInPeriod(start).Select(date => new Candidate(date, date.Month)).ToArray();
    }

    private IReadOnlyList<DateOnly> DatesInPeriod(DateOnly start) => _expr switch
    {
        IntervalRepeat ir => ir.DayFilter is null || Calendar.MatchesDayFilter(start, ir.DayFilter) ? [start] : [],
        DayRepeat dr => Calendar.MatchesDayFilter(start, dr.Days) ? [start] : [],
        WeekRepeat wr => wr.WeekDays
            .Select(day => (long)start.DayNumber + day.Number() - 1)
            .Where(day => day <= DateOnly.MaxValue.DayNumber)
            .Order()
            .Select(day => DateOnly.FromDayNumber((int)day))
            .ToList(),
        YearRepeat yr => Calendar.YearTargetDate(start.Year, yr.Target) is { } date ? [date] : [],
        SingleDate { DateSpec.Kind: DateSpecKind.Named } sd =>
            Calendar.TryCreateDate(start.Year, sd.DateSpec.Month!.Value.Number(), sd.DateSpec.Day) is { } date ? [date] : [],
        SingleDate => [start],
        _ => []
    };

    private static IEnumerable<T> InOrder<T>(IReadOnlyList<T> items, Direction direction)
    {
        return direction == Direction.Forward ? items : items.Reverse();
    }
}
