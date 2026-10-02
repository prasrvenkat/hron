using Hron.Ast;

namespace Hron.Eval;

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
        DateOnly? starting = data.Starting is null ? null : IsoDate.Parse(data.Starting);
        return new Search(
            data.Expression,
            zone,
            Cadence.Of(data.Expression, starting),
            DailyTimes.Of(data.Expression),
            Clauses.Of(data, starting));
    }

    public void EndOn(DateOnly date) => _clauses.EndOn(date);

    public DateTimeOffset? Nearest(DateTimeOffset now, Direction direction)
    {
        var nowDate = WallClock.LocalDate(now, _zone);
        var firstDate = _clauses.Clamp(nowDate, direction);
        // A nearest weekday or a DST shift can move an occurrence out of the period it is
        // scheduled in, so the search starts one period back.
        var firstPeriod = _cadence.PeriodOf(firstDate) - direction.Sign();
        var reach = _clauses.FarthestExceptDate(direction) is { } except ? _cadence.PeriodOf(except) : firstPeriod;
        var shift = _times.MaxShiftDays;
        Occurrence? best = null;
        foreach (var period in _cadence.Periods(firstPeriod, reach, direction))
        {
            if (RejectsPeriod(period))
            {
                continue;
            }
            foreach (var candidate in InOrder(CandidatesInPeriod(period), direction))
            {
                var beaten = best is { } found && !found.CouldBeat(candidate.Date, direction, shift);
                if (beaten || _clauses.EndsSearch(candidate.Date, direction))
                {
                    return best?.Instant;
                }
                if (Occurrence.IsBehind(candidate.Date, nowDate, direction, shift) || !_clauses.Allows(candidate))
                {
                    continue;
                }
                if (NearestOnDate(candidate.Date, now, direction) is { } instant &&
                    (best is not { } current || direction.Precedes(instant, current.Instant)))
                {
                    best = Occurrence.At(instant);
                }
            }
        }
        return best?.Instant;
    }

    /// <summary>
    /// A day or month period's candidates all target its own month, so one whose month
    /// <c>during</c> rejects holds nothing.
    /// </summary>
    private bool RejectsPeriod(long period) => _cadence.MonthOf(period) is { } month && !_clauses.AllowsMonth(month);

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

    private DateTimeOffset? NearestSlot(DailyTimes.Slots slots, DateOnly date, DateTimeOffset now, Direction direction)
    {
        var offsets = WallClock.OffsetsOn(date, _zone);
        Slot SlotAt(long index) => WallClock.SlotOn(date, slots.MinuteAt(index), offsets, _zone);
        var (low, high) = (0L, slots.Count);
        while (low < high)
        {
            var mid = low + (high - low) / 2;
            var key = SlotAt(mid).Key;
            if (key < now.UtcTicks || (direction == Direction.Forward && key == now.UtcTicks))
            {
                low = mid + 1;
            }
            else
            {
                high = mid;
            }
        }
        for (var index = direction == Direction.Forward ? low : low - 1; index >= 0 && index < slots.Count; index += direction.Sign())
        {
            if (SlotAt(index).Instant is { } instant)
            {
                return instant;
            }
        }
        return null;
    }

    private IReadOnlyList<Candidate> CandidatesInPeriod(long period)
    {
        if (_expr is MonthRepeat mr)
        {
            var month = _cadence.MonthIndexOf(period);
            var targetMonth = Calendar.MonthOf(month);
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
            .Select(day => Calendar.AddDays(start, day.Number() - 1))
            .OfType<DateOnly>()
            .Order()
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
