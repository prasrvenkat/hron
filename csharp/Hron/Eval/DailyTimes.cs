using Hron.Ast;

namespace Hron.Eval;

/// <summary>
/// The times of day an expression fires at.
/// </summary>
internal abstract record DailyTimes
{
    private DailyTimes()
    {
    }

    /// <summary>
    /// Fixed times, each shifted out of a gap.
    /// </summary>
    public sealed record Fixed(IReadOnlyList<TimeOfDay> Times) : DailyTimes;

    /// <summary>
    /// Interval slots <c>From + k × Step</c> up to and including <c>To</c>, in minutes after
    /// midnight, each skipped in a gap.
    /// </summary>
    public sealed record Slots(long From, long To, long Step) : DailyTimes
    {
        /// <summary>
        /// The slots from <paramref name="earliest"/> to <paramref name="latest"/> inclusive, in
        /// <paramref name="direction"/> order.
        /// </summary>
        public IEnumerable<long> Within(long earliest, long latest, Direction direction)
        {
            var low = Math.Max(From, earliest);
            var high = Math.Min(To, latest);
            if (low > high)
            {
                yield break;
            }
            var first = From + (low - From + Step - 1) / Step * Step;
            var last = From + (high - From) / Step * Step;
            var step = direction.Sign() * Step;
            for (var minute = direction == Direction.Forward ? first : last; minute >= first && minute <= last; minute += step)
            {
                yield return minute;
            }
        }
    }

    public static DailyTimes Of(IScheduleExpr expr) => expr switch
    {
        IntervalRepeat ir => new Slots(
            ir.FromTime.TotalMinutes,
            ir.ToTime.TotalMinutes,
            Math.Max((long)ir.Interval * (ir.Unit == IntervalUnit.Minutes ? 1 : WallClock.MinutesPerHour), 1)),
        DayRepeat dr => new Fixed(dr.Times),
        WeekRepeat wr => new Fixed(wr.Times),
        MonthRepeat mr => new Fixed(mr.Times),
        SingleDate sd => new Fixed(sd.Times),
        YearRepeat yr => new Fixed(yr.Times),
        _ => new Fixed([])
    };
}
