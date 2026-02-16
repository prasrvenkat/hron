using System.Text;
using Hron.Ast;

namespace Hron.Display;

/// <summary>
/// Renders schedule data as canonical strings.
/// </summary>
public static class Display
{
    /// <summary>
    /// Renders a schedule data as a canonical string.
    /// </summary>
    public static string Render(ScheduleData data)
    {
        var sb = new StringBuilder();

        sb.Append(RenderExpr(data.Expr));

        if (data.Except.Count > 0)
        {
            sb.Append(" except ");
            sb.Append(RenderExceptions(data.Except));
        }

        if (data.Until is not null)
        {
            sb.Append(" until ");
            sb.Append(RenderUntil(data.Until));
        }

        if (!string.IsNullOrEmpty(data.Anchor))
        {
            sb.Append(" starting ");
            sb.Append(data.Anchor);
        }

        if (data.During.Count > 0)
        {
            sb.Append(" during ");
            sb.Append(RenderMonthList(data.During));
        }

        if (!string.IsNullOrEmpty(data.Timezone))
        {
            sb.Append(" in ");
            sb.Append(data.Timezone);
        }

        return sb.ToString();
    }

    private static string RenderExpr(IScheduleExpr expr) => expr switch
    {
        DayRepeat dr => RenderDayRepeat(dr),
        IntervalRepeat ir => RenderIntervalRepeat(ir),
        WeekRepeat wr => RenderWeekRepeat(wr),
        MonthRepeat mr => RenderMonthRepeat(mr),
        SingleDate sd => RenderSingleDate(sd),
        YearRepeat yr => RenderYearRepeat(yr),
        _ => throw new ArgumentException($"Unknown expression type: {expr.GetType()}", nameof(expr))
    };

    private static string RenderDayRepeat(DayRepeat dr)
    {
        if (dr.Interval > 1)
        {
            return $"every {dr.Interval} days at {FormatTimeList(dr.Times)}";
        }
        return $"every {RenderDayFilter(dr.Days)} at {FormatTimeList(dr.Times)}";
    }

    private static string RenderIntervalRepeat(IntervalRepeat ir)
    {
        var sb = new StringBuilder();
        sb.Append($"every {ir.Interval} {ir.Unit.Display(ir.Interval)} from {ir.FromTime} to {ir.ToTime}");
        if (ir.DayFilter is not null)
        {
            sb.Append(" on ");
            sb.Append(RenderDayFilter(ir.DayFilter));
        }
        return sb.ToString();
    }

    private static string RenderWeekRepeat(WeekRepeat wr)
        => $"every {wr.Interval} weeks on {FormatDayList(wr.WeekDays)} at {FormatTimeList(wr.Times)}";

    private static string RenderMonthRepeat(MonthRepeat mr)
    {
        var targetStr = RenderMonthTarget(mr.Target);
        if (mr.Interval > 1)
        {
            return $"every {mr.Interval} months on the {targetStr} at {FormatTimeList(mr.Times)}";
        }
        return $"every month on the {targetStr} at {FormatTimeList(mr.Times)}";
    }

    private static string RenderSingleDate(SingleDate sd)
        => $"on {RenderDateSpec(sd.DateSpec)} at {FormatTimeList(sd.Times)}";

    private static string RenderYearRepeat(YearRepeat yr)
    {
        var targetStr = RenderYearTarget(yr.Target);
        if (yr.Interval > 1)
        {
            return $"every {yr.Interval} years on {targetStr} at {FormatTimeList(yr.Times)}";
        }
        return $"every year on {targetStr} at {FormatTimeList(yr.Times)}";
    }

    private static string RenderDayFilter(DayFilter f) => f.Kind switch
    {
        DayFilterKind.Every => "day",
        DayFilterKind.Weekday => "weekday",
        DayFilterKind.Weekend => "weekend",
        DayFilterKind.Days => FormatDayList(f.Days),
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderMonthTarget(MonthTarget target) => target.Kind switch
    {
        MonthTargetKind.LastDay => "last day",
        MonthTargetKind.LastWeekday => "last weekday",
        MonthTargetKind.Days => FormatOrdinalDaySpecs(target.Specs),
        MonthTargetKind.NearestWeekday => RenderNearestWeekday(target),
        MonthTargetKind.OrdinalWeekday => $"{target.OrdinalValue!.Value.ToDisplayString()} {target.WeekdayValue!.Value.ToDisplayString()}",
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderNearestWeekday(MonthTarget target)
    {
        var prefix = target.NearestWeekdayDirection switch
        {
            NearestDirection.Next => "next ",
            NearestDirection.Previous => "previous ",
            _ => ""
        };
        return $"{prefix}nearest weekday to {OrdinalNumber(target.NearestWeekdayDay)}";
    }

    private static string RenderYearTarget(YearTarget target) => target.Kind switch
    {
        YearTargetKind.Date => $"{target.Month.ToDisplayString()} {target.Day}",
        YearTargetKind.OrdinalWeekday => $"the {target.Ordinal!.Value.ToDisplayString()} {target.WeekdayValue!.Value.ToDisplayString()} of {target.Month.ToDisplayString()}",
        YearTargetKind.DayOfMonth => $"the {OrdinalNumber(target.Day)} of {target.Month.ToDisplayString()}",
        YearTargetKind.LastWeekday => $"the last weekday of {target.Month.ToDisplayString()}",
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderDateSpec(DateSpec spec) => spec.Kind switch
    {
        DateSpecKind.Named => $"{spec.Month!.Value.ToDisplayString()} {spec.Day}",
        DateSpecKind.Iso => spec.Date!,
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderExceptions(IReadOnlyList<ExceptionSpec> exceptions)
        => string.Join(", ", exceptions.Select(RenderExceptionSpec));

    private static string RenderExceptionSpec(ExceptionSpec exc) => exc.Kind switch
    {
        ExceptionSpecKind.Named => $"{exc.Month!.Value.ToDisplayString()} {exc.Day}",
        ExceptionSpecKind.Iso => exc.Date!,
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderUntil(UntilSpec until) => until.Kind switch
    {
        UntilSpecKind.Iso => until.Date!,
        UntilSpecKind.Named => $"{until.Month!.Value.ToDisplayString()} {until.Day}",
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string RenderMonthList(IReadOnlyList<MonthName> months)
        => string.Join(", ", months.Select(m => m.ToDisplayString()));

    private static string FormatTimeList(IReadOnlyList<TimeOfDay> times)
        => string.Join(", ", times.Select(t => t.ToString()));

    private static string FormatDayList(IReadOnlyList<Weekday> days)
        => string.Join(", ", days.Select(d => d.ToDisplayString()));

    private static string FormatOrdinalDaySpecs(IReadOnlyList<DayOfMonthSpec> specs)
        => string.Join(", ", specs.Select(FormatDayOfMonthSpec));

    private static string FormatDayOfMonthSpec(DayOfMonthSpec spec) => spec.Kind switch
    {
        DayOfMonthSpecKind.Single => OrdinalNumber(spec.Day),
        DayOfMonthSpecKind.Range => $"{OrdinalNumber(spec.Start)} to {OrdinalNumber(spec.End)}",
        _ => throw new ArgumentOutOfRangeException()
    };

    private static string OrdinalNumber(int n) => n + OrdinalSuffix(n);

    private static string OrdinalSuffix(int n)
    {
        var mod100 = n % 100;
        if (mod100 is >= 11 and <= 13)
        {
            return "th";
        }
        return (n % 10) switch
        {
            1 => "st",
            2 => "nd",
            3 => "rd",
            _ => "th"
        };
    }
}
