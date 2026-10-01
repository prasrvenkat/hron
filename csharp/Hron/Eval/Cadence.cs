using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// The periods (days, weeks, months or years) an expression fires in, numbered from an origin:
/// period <c>k</c> is aligned when <c>k</c> is a multiple of the interval.
/// </summary>
internal sealed class Cadence
{
    /// <summary>
    /// Slack beyond the horizon for the period one behind the first date's, where a search starts,
    /// and for a horizon that starts mid-period.
    /// </summary>
    private const long HorizonMarginPeriods = 2;

    /// <summary>
    /// Default anchor for week intervals (spec/README.md, "WeekRepeat epoch alignment").
    /// </summary>
    private static readonly DateOnly EpochMonday = new(1970, 1, 5);

    /// <summary>
    /// Default anchor for day, month and year intervals, and for a named until.
    /// </summary>
    public static readonly DateOnly EpochDate = new(1970, 1, 1);

    private enum Unit
    {
        Day,
        Week,
        Month,
        Year
    }

    private readonly Unit _unit;
    private readonly DateOnly _origin;
    private readonly long _interval;

    /// <summary>
    /// A single ISO date has one period, the one holding that date.
    /// </summary>
    private readonly bool _single;

    /// <summary>
    /// The first period that can hold a date DateOnly represents: the one before the period of
    /// 0001-01-01, since the nearest weekday of December of year 0 can land on 0001-01-01.
    /// </summary>
    private readonly long _firstInCalendar;

    private readonly long _lastInCalendar;

    private Cadence(Unit unit, DateOnly origin, long interval, bool single)
    {
        _unit = unit;
        _origin = origin;
        _interval = interval;
        _single = single;
        _firstInCalendar = PeriodOf(DateOnly.MinValue) - 1;
        _lastInCalendar = PeriodOf(DateOnly.MaxValue);
    }

    public static Cadence Of(IScheduleExpr expr, DateOnly? starting)
    {
        if (expr is SingleDate { DateSpec.Kind: DateSpecKind.Iso } single)
        {
            return new Cadence(Unit.Day, IsoDate.Parse(single.DateSpec.Date!), 1, single: true);
        }
        var (unit, interval, defaultOrigin) = expr switch
        {
            DayRepeat dr => (Unit.Day, dr.Interval, EpochDate),
            WeekRepeat wr => (Unit.Week, wr.Interval, EpochMonday),
            MonthRepeat mr => (Unit.Month, mr.Interval, EpochDate),
            YearRepeat yr => (Unit.Year, yr.Interval, EpochDate),
            SingleDate => (Unit.Year, 1, EpochDate),
            IntervalRepeat => (Unit.Day, 1, EpochDate),
            _ => (Unit.Day, 1, EpochDate)
        };
        var anchor = starting ?? defaultOrigin;
        var origin = unit switch
        {
            Unit.Week => Calendar.MondayOf(anchor),
            Unit.Month => new DateOnly(anchor.Year, anchor.Month, 1),
            Unit.Year => new DateOnly(anchor.Year, 1, 1),
            _ => anchor
        };
        return new Cadence(unit, origin, Math.Max(interval, 1), single: false);
    }

    public long PeriodOf(DateOnly date) => _unit switch
    {
        Unit.Week => Calendar.FloorDiv(date.DayNumber - _origin.DayNumber, 7),
        Unit.Month => Calendar.MonthIndex(date) - Calendar.MonthIndex(_origin),
        Unit.Year => date.Year - _origin.Year,
        _ => date.DayNumber - _origin.DayNumber
    };

    /// <summary>
    /// First day of period <paramref name="k"/>, or null when DateOnly cannot represent it.
    /// </summary>
    public DateOnly? StartOf(long k) => _unit switch
    {
        Unit.Week => Calendar.AddDays(_origin, 7 * k),
        Unit.Month => Calendar.FirstOfMonth(MonthIndexOf(k)),
        Unit.Year => Calendar.FirstOfYear(_origin.Year + k),
        _ => Calendar.AddDays(_origin, k)
    };

    /// <summary>
    /// The month of period <paramref name="k"/> of a monthly cadence, in months since January of
    /// year 0, which DateOnly may not represent.
    /// </summary>
    public long MonthIndexOf(long k) => Calendar.MonthIndex(_origin) + k;

    /// <summary>
    /// The aligned periods from <paramref name="firstPeriod"/> in <paramref name="direction"/>,
    /// through one search horizon beyond whichever of <paramref name="firstPeriod"/> and
    /// <paramref name="reach"/> is farther along it (spec/README.md, "Search horizon"). The first
    /// period beyond the calendar ends the walk.
    /// </summary>
    public IEnumerable<long> Periods(long firstPeriod, long reach, Direction direction)
    {
        long first, count;
        if (_single)
        {
            (first, count) = (0, 1);
        }
        else
        {
            first = Align(firstPeriod, direction);
            var beyond = direction.Sign() * (Align(reach, direction) - first);
            count = HorizonPeriods() + HorizonMarginPeriods + Math.Max(beyond, 0) / _interval;
        }
        var edge = direction == Direction.Forward ? _lastInCalendar : _firstInCalendar;
        var (k, step) = (first, direction.Sign() * _interval);
        for (long i = 0; i < count && !direction.Precedes(edge, k); i++, k += step)
        {
            yield return k;
        }
    }

    /// <summary>
    /// The first aligned period at or beyond period <paramref name="k"/> in
    /// <paramref name="direction"/>.
    /// </summary>
    private long Align(long k, Direction direction) => direction switch
    {
        Direction.Forward => k + Calendar.FloorMod(-k, _interval),
        _ => k - Calendar.FloorMod(k, _interval)
    };

    /// <summary>
    /// Aligned periods in lcm(400 years, interval units), after which both the calendar and the
    /// alignment repeat.
    /// </summary>
    private long HorizonPeriods()
    {
        var cycle = Per400Years(_unit);
        return cycle / Gcd(cycle, _interval);
    }

    /// <summary>
    /// Units in 400 years, after which the proleptic Gregorian calendar repeats.
    /// </summary>
    private static long Per400Years(Unit unit) => unit switch
    {
        Unit.Week => Calendar.DaysPer400Years / 7,
        Unit.Month => Calendar.MonthsPer400Years,
        Unit.Year => 400,
        _ => Calendar.DaysPer400Years
    };

    private static long Gcd(long a, long b) => b == 0 ? a : Gcd(b, a % b);
}
