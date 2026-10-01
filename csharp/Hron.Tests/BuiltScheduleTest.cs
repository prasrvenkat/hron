using Hron.Ast;
using Hron.Eval;
using Xunit;

namespace Hron.Tests;

/// <summary>
/// Schedules built from ScheduleData rather than parsed, which can hold what parse rejects.
/// </summary>
public class BuiltScheduleTest
{
    private static readonly DateTimeOffset Now = new(2026, 2, 6, 12, 0, 0, TimeSpan.Zero);

    private static readonly IReadOnlyList<TimeOfDay> NineAm = [new TimeOfDay(9, 0)];

    [Fact]
    public void NamedUntilWithoutStartingResolvesFromTheEpoch()
    {
        var data = ScheduleData.Of(new DayRepeat(1, DayFilter.Every(), NineAm))
            .WithUntil(UntilSpec.Named(MonthName.December, 31));

        Assert.Null(Evaluator.NextFrom(data, Now, TimeZoneInfo.Utc));
        Assert.Equal(
            new DateTimeOffset(1970, 12, 31, 9, 0, 0, TimeSpan.Zero),
            Evaluator.PreviousFrom(data, Now, TimeZoneInfo.Utc));
    }

    [Fact]
    public void DayIntervalZeroActsAsOne()
    {
        AssertSameNextThree(
            new DayRepeat(0, DayFilter.Every(), NineAm),
            new DayRepeat(1, DayFilter.Every(), NineAm));
    }

    [Fact]
    public void MinuteIntervalZeroActsAsOne()
    {
        AssertSameNextThree(
            new IntervalRepeat(0, IntervalUnit.Minutes, new TimeOfDay(9, 0), new TimeOfDay(9, 5), null),
            new IntervalRepeat(1, IntervalUnit.Minutes, new TimeOfDay(9, 0), new TimeOfDay(9, 5), null));
    }

    private static void AssertSameNextThree(IScheduleExpr zero, IScheduleExpr one)
    {
        var expected = Evaluator.NextNFrom(ScheduleData.Of(one), Now, 3, TimeZoneInfo.Utc);
        Assert.Equal(3, expected.Count);
        Assert.Equal(expected, Evaluator.NextNFrom(ScheduleData.Of(zero), Now, 3, TimeZoneInfo.Utc));
    }
}
