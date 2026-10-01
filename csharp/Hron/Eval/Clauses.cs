using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// The trailing clauses, resolved once. <c>during</c> applies to a candidate's target month;
/// <c>except</c>, <c>until</c> and <c>starting</c> to its date (spec/README.md, "Nearest weekday
/// and `during`", "The `starting` clause").
/// </summary>
internal sealed class Clauses
{
    /// <summary>
    /// Feb 29 can be eight years away, as from 2096-03-01 to 2104-02-29.
    /// </summary>
    private const int NamedUntilMaxYears = 8;

    private readonly int[] _during;
    private readonly (int Month, int Day)[] _exceptMonthDays;
    private readonly DateOnly[] _exceptDates;
    private readonly DateOnly? _until;
    private readonly DateOnly? _starting;

    private Clauses(int[] during, (int Month, int Day)[] exceptMonthDays, DateOnly[] exceptDates, DateOnly? until, DateOnly? starting)
    {
        _during = during;
        _exceptMonthDays = exceptMonthDays;
        _exceptDates = exceptDates;
        _until = until;
        _starting = starting;
    }

    /// <summary>
    /// The clauses of <paramref name="data"/>, whose <c>starting</c> date is
    /// <paramref name="starting"/>.
    /// </summary>
    public static Clauses Of(ScheduleData data, DateOnly? starting)
    {
        return new Clauses(
            data.During.Select(month => month.Number()).ToArray(),
            data.Except
                .Where(exception => exception.Kind == ExceptionSpecKind.Named)
                .Select(exception => (exception.Month!.Value.Number(), exception.Day))
                .ToArray(),
            data.Except
                .Where(exception => exception.Kind == ExceptionSpecKind.Iso)
                .Select(exception => IsoDate.Parse(exception.Date!))
                .Order()
                .ToArray(),
            data.Until is { } until ? ResolveUntil(until, starting) : null,
            starting);
    }

    /// <summary>
    /// These clauses with <c>until</c> at most <paramref name="date"/>.
    /// </summary>
    public Clauses EndingOn(DateOnly date)
    {
        var until = _until is { } current && current < date ? current : date;
        return new Clauses(_during, _exceptMonthDays, _exceptDates, until, _starting);
    }

    public bool Allows(Candidate candidate)
    {
        var date = candidate.Date;
        return AllowsTargetMonth(candidate.TargetMonth)
            && !_exceptMonthDays.Contains((date.Month, date.Day))
            && Array.BinarySearch(_exceptDates, date) < 0
            && (_until is not { } until || date <= until)
            && (_starting is not { } starting || date >= starting);
    }

    public bool AllowsTargetMonth(int month) => _during.Length == 0 || _during.Contains(month);

    /// <summary>
    /// The one-off except date farthest along <paramref name="direction"/>: the calendar repeats
    /// only beyond it (spec/README.md, "Search horizon").
    /// </summary>
    public DateOnly? FarthestExceptDate(Direction direction)
    {
        if (_exceptDates.Length == 0)
        {
            return null;
        }
        return direction == Direction.Forward ? _exceptDates[^1] : _exceptDates[0];
    }

    /// <summary>
    /// The date a search starts from: nothing fires before <c>starting</c> or after <c>until</c>.
    /// </summary>
    public DateOnly Clamp(DateOnly date, Direction direction) => direction switch
    {
        Direction.Forward when _starting is { } starting && starting > date => starting,
        Direction.Backward when _until is { } until && until < date => until,
        _ => date
    };

    /// <summary>
    /// Whether <paramref name="date"/>, and every date beyond it in <paramref name="direction"/>,
    /// is past the bound the search moves toward.
    /// </summary>
    public bool EndsSearch(DateOnly date, Direction direction) => direction switch
    {
        Direction.Forward => _until is { } until && date > until,
        _ => _starting is { } starting && date < starting
    };

    /// <summary>
    /// A named until date is the first such date on or after the starting date
    /// (spec/README.md, "Named `until`"). Parse requires <c>starting</c>; a ScheduleData built
    /// without one resolves from the default anchor, the epoch. Null when no such date exists
    /// before the calendar ends, so nothing bounds the schedule.
    /// </summary>
    private static DateOnly? ResolveUntil(UntilSpec until, DateOnly? starting)
    {
        if (until.Kind == UntilSpecKind.Iso)
        {
            return IsoDate.Parse(until.Date!);
        }
        var from = starting ?? Cadence.EpochDate;
        var lastYear = Math.Min(from.Year + NamedUntilMaxYears, DateOnly.MaxValue.Year);
        for (var year = from.Year; year <= lastYear; year++)
        {
            if (Calendar.TryCreateDate(year, until.Month!.Value.Number(), until.Day) is { } date && date >= from)
            {
                return date;
            }
        }
        return null;
    }
}
