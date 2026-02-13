using Hron.Ast;

namespace Hron.Cron;

/// <summary>
/// Converts between hron expressions and 5-field cron expressions.
/// </summary>
public static class CronConverter
{
    /// <summary>
    /// Converts a schedule to a 5-field cron expression.
    /// </summary>
    public static string ToCron(ScheduleData data)
    {
        if (data.Except.Count > 0)
        {
            throw HronException.Cron("not expressible as cron (except clauses not supported)");
        }
        if (data.Until is not null)
        {
            throw HronException.Cron("not expressible as cron (until clauses not supported)");
        }
        if (data.During.Count > 0)
        {
            throw HronException.Cron("not expressible as cron (during clauses not supported)");
        }

        return data.Expr switch
        {
            DayRepeat dr => DayRepeatToCron(dr),
            IntervalRepeat ir => IntervalRepeatToCron(ir),
            WeekRepeat => throw HronException.Cron("not expressible as cron (multi-week intervals not supported)"),
            MonthRepeat mr => MonthRepeatToCron(mr),
            OrdinalRepeat => throw HronException.Cron("not expressible as cron (ordinal weekday of month not supported)"),
            SingleDate => throw HronException.Cron("not expressible as cron (single dates are not repeating)"),
            YearRepeat => throw HronException.Cron("not expressible as cron (yearly schedules not supported in 5-field cron)"),
            _ => throw new ArgumentException($"Unknown expression type: {data.Expr.GetType()}", nameof(data))
        };
    }

    private static string DayRepeatToCron(DayRepeat dr)
    {
        if (dr.Interval > 1)
        {
            throw HronException.Cron("not expressible as cron (multi-day intervals not supported)");
        }
        if (dr.Times.Count != 1)
        {
            throw HronException.Cron("not expressible as cron (multiple times not supported)");
        }

        var t = dr.Times[0];
        var dow = DayFilterToCronDOW(dr.Days);

        return $"{t.Minute} {t.Hour} * * {dow}";
    }

    private static string IntervalRepeatToCron(IntervalRepeat ir)
    {
        var fullDay = ir.FromTime.Hour == 0
            && ir.FromTime.Minute == 0
            && ir.ToTime.Hour == 23
            && ir.ToTime.Minute == 59;

        if (!fullDay)
        {
            throw HronException.Cron("not expressible as cron (partial-day interval windows not supported)");
        }
        if (ir.DayFilter is not null)
        {
            throw HronException.Cron("not expressible as cron (interval with day filter not supported)");
        }

        if (ir.Unit == IntervalUnit.Minutes)
        {
            if (60 % ir.Interval != 0)
            {
                throw HronException.Cron($"not expressible as cron (*/{ir.Interval} breaks at hour boundaries)");
            }
            return $"*/{ir.Interval} * * * *";
        }

        // Hours
        return $"0 */{ir.Interval} * * *";
    }

    private static string MonthRepeatToCron(MonthRepeat mr)
    {
        if (mr.Interval > 1)
        {
            throw HronException.Cron("not expressible as cron (multi-month intervals not supported)");
        }
        if (mr.Times.Count != 1)
        {
            throw HronException.Cron("not expressible as cron (multiple times not supported)");
        }

        var t = mr.Times[0];

        return mr.Target.Kind switch
        {
            MonthTargetKind.Days => $"{t.Minute} {t.Hour} {FormatIntList(mr.Target.ExpandDays())} * *",
            MonthTargetKind.LastDay => throw HronException.Cron("not expressible as cron (last day of month not supported)"),
            MonthTargetKind.LastWeekday => throw HronException.Cron("not expressible as cron (last weekday of month not supported)"),
            _ => throw new ArgumentException("Unknown month target kind")
        };
    }

    private static string DayFilterToCronDOW(DayFilter f)
    {
        return f.Kind switch
        {
            DayFilterKind.Every => "*",
            DayFilterKind.Weekday => "1-5",
            DayFilterKind.Weekend => "0,6",
            DayFilterKind.Days => FormatIntList(f.Days.Select(w => w.CronDOW()).Order().ToList()),
            _ => throw new ArgumentException("Unknown day filter kind")
        };
    }

    private static string FormatIntList(IReadOnlyList<int> nums)
        => string.Join(",", nums);

    /// <summary>
    /// Converts a 5-field cron expression to a ScheduleData.
    /// </summary>
    public static ScheduleData FromCron(string cron)
    {
        var fields = cron.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 5)
        {
            throw HronException.Cron($"expected 5 cron fields, got {fields.Length}");
        }

        var minuteField = fields[0];
        var hourField = fields[1];
        var domField = fields[2];
        // var monthField = fields[3]; // not used
        var dowField = fields[4];

        // Minute interval: */N
        if (minuteField.StartsWith("*/"))
        {
            if (!int.TryParse(minuteField.AsSpan(2), out var interval))
            {
                throw HronException.Cron("invalid minute interval");
            }

            var fromHour = 0;
            var toHour = 23;

            if (hourField != "*")
            {
                if (hourField.Contains('-'))
                {
                    var parts = hourField.Split('-');
                    if (parts.Length != 2)
                    {
                        throw HronException.Cron("invalid hour range");
                    }
                    if (!int.TryParse(parts[0], out fromHour) || !int.TryParse(parts[1], out toHour))
                    {
                        throw HronException.Cron("invalid hour range");
                    }
                }
                else
                {
                    if (!int.TryParse(hourField, out fromHour))
                    {
                        throw HronException.Cron("invalid hour");
                    }
                    toHour = fromHour;
                }
            }

            DayFilter? dayFilter = null;
            if (dowField != "*")
            {
                dayFilter = ParseCronDOW(dowField);
            }

            if (domField == "*")
            {
                var toMin = toHour != 23 ? 0 : 59;
                return ScheduleData.Of(
                    new IntervalRepeat(
                        interval,
                        IntervalUnit.Minutes,
                        new TimeOfDay(fromHour, 0),
                        new TimeOfDay(toHour, toMin),
                        dayFilter));
            }
        }

        // Hour interval: 0 */N
        if (hourField.StartsWith("*/") && minuteField == "0")
        {
            if (!int.TryParse(hourField.AsSpan(2), out var interval))
            {
                throw HronException.Cron("invalid hour interval");
            }

            if (domField == "*" && dowField == "*")
            {
                return ScheduleData.Of(
                    new IntervalRepeat(
                        interval, IntervalUnit.Hours, new TimeOfDay(0, 0), new TimeOfDay(23, 59), null));
            }
        }

        // Standard time-based cron
        if (!int.TryParse(minuteField, out var minute) || !int.TryParse(hourField, out var hour))
        {
            throw HronException.Cron($"invalid minute/hour field: {minuteField} {hourField}");
        }

        var t = new TimeOfDay(hour, minute);

        // DOM-based (monthly)
        if (domField != "*" && dowField == "*")
        {
            if (domField.Contains('-'))
            {
                throw HronException.Cron($"DOM ranges not supported: {domField}");
            }

            var specs = new List<DayOfMonthSpec>();
            foreach (var s in domField.Split(','))
            {
                if (!int.TryParse(s, out var day))
                {
                    throw HronException.Cron($"invalid DOM field: {domField}");
                }
                specs.Add(DayOfMonthSpec.Single(day));
            }

            return ScheduleData.Of(new MonthRepeat(1, MonthTarget.Days(specs), [t]));
        }

        // DOW-based (day repeat)
        var days = ParseCronDOW(dowField);
        return ScheduleData.Of(new DayRepeat(1, days, [t]));
    }

    private static DayFilter ParseCronDOW(string field)
    {
        if (field == "*")
        {
            return DayFilter.Every();
        }
        if (field == "1-5")
        {
            return DayFilter.Weekday();
        }
        if (field is "0,6" or "6,0")
        {
            return DayFilter.Weekend();
        }

        if (field.Contains('-'))
        {
            throw HronException.Cron($"DOW ranges not supported: {field}");
        }

        var days = new List<Weekday>();
        foreach (var s in field.Split(','))
        {
            if (!int.TryParse(s, out var n))
            {
                throw HronException.Cron($"invalid DOW field: {field}");
            }

            var wd = CronDOWToWeekday(n);
            if (wd is null)
            {
                throw HronException.Cron($"invalid DOW number: {n}");
            }
            days.Add(wd.Value);
        }

        return DayFilter.SpecificDays(days);
    }

    private static Weekday? CronDOWToWeekday(int n) => n switch
    {
        0 or 7 => Weekday.Sunday,
        1 => Weekday.Monday,
        2 => Weekday.Tuesday,
        3 => Weekday.Wednesday,
        4 => Weekday.Thursday,
        5 => Weekday.Friday,
        6 => Weekday.Saturday,
        _ => null
    };
}
