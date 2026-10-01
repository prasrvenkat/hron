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
        public long Count => Math.Max(Calendar.FloorDiv(To - From, Step) + 1, 0);

        public long MinuteAt(long index) => From + index * Step;
    }

    /// <summary>
    /// How many dates past its scheduled date an occurrence can land: a gap pushes a fixed time
    /// forward, and skips a slot.
    /// </summary>
    public int MaxShiftDays => this is Fixed ? Occurrence.MaxShiftDays : 0;

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
