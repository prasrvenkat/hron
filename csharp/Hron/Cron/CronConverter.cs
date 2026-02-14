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
        cron = cron.Trim();

        // Handle @ shortcuts first
        if (cron.StartsWith('@'))
        {
            return ParseCronShortcut(cron);
        }

        var fields = cron.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 5)
        {
            throw HronException.Cron($"expected 5 cron fields, got {fields.Length}");
        }

        var minuteField = fields[0];
        var hourField = fields[1];
        var domField = fields[2];
        var monthField = fields[3];
        var dowField = fields[4];

        // Normalize ? to * (they're semantically equivalent for our purposes)
        if (domField == "?") domField = "*";
        if (dowField == "?") dowField = "*";

        // Parse month field into during clause
        var during = ParseMonthField(monthField);

        // Check for special DOW patterns: nth weekday (#), last weekday (5L)
        var nthWeekday = TryParseNthWeekday(minuteField, hourField, domField, dowField, during);
        if (nthWeekday is not null)
        {
            return nthWeekday;
        }

        // Check for L (last day) or LW (last weekday) in DOM
        var lastDay = TryParseLastDay(minuteField, hourField, domField, dowField, during);
        if (lastDay is not null)
        {
            return lastDay;
        }

        // Check for W (nearest weekday) - not yet supported
        if (domField.EndsWith('W') && domField != "LW")
        {
            throw HronException.Cron("W (nearest weekday) not yet supported");
        }

        // Check for interval patterns: */N or range/N
        var interval = TryParseInterval(minuteField, hourField, domField, dowField, during);
        if (interval is not null)
        {
            return interval;
        }

        // Standard time-based cron
        var minute = ParseSingleValue(minuteField, "minute", 0, 59);
        var hour = ParseSingleValue(hourField, "hour", 0, 23);
        var time = new TimeOfDay(hour, minute);

        // DOM-based (monthly) - when DOM is specified and DOW is *
        if (domField != "*" && dowField == "*")
        {
            var target = ParseDomField(domField);
            return ScheduleData.Of(new MonthRepeat(1, target, [time])).WithDuring(during);
        }

        // DOW-based (day repeat)
        var days = ParseCronDOW(dowField);
        return ScheduleData.Of(new DayRepeat(1, days, [time])).WithDuring(during);
    }

    /// <summary>
    /// Parse @ shortcuts like @daily, @hourly, etc.
    /// </summary>
    private static ScheduleData ParseCronShortcut(string cron)
    {
        return cron.ToLowerInvariant() switch
        {
            "@yearly" or "@annually" => ScheduleData.Of(new YearRepeat(
                1,
                YearTarget.Date(MonthName.January, 1),
                [new TimeOfDay(0, 0)])),
            "@monthly" => ScheduleData.Of(new MonthRepeat(
                1,
                MonthTarget.Days([DayOfMonthSpec.Single(1)]),
                [new TimeOfDay(0, 0)])),
            "@weekly" => ScheduleData.Of(new DayRepeat(
                1,
                DayFilter.SpecificDays([Weekday.Sunday]),
                [new TimeOfDay(0, 0)])),
            "@daily" or "@midnight" => ScheduleData.Of(new DayRepeat(
                1,
                DayFilter.Every(),
                [new TimeOfDay(0, 0)])),
            "@hourly" => ScheduleData.Of(new IntervalRepeat(
                1,
                IntervalUnit.Hours,
                new TimeOfDay(0, 0),
                new TimeOfDay(23, 59),
                null)),
            _ => throw HronException.Cron($"unknown @ shortcut: {cron}")
        };
    }

    /// <summary>
    /// Parse month field into a list of MonthName for the `during` clause.
    /// </summary>
    private static List<MonthName> ParseMonthField(string field)
    {
        if (field == "*")
        {
            return [];
        }

        var months = new List<MonthName>();
        foreach (var part in field.Split(','))
        {
            // Check for step values FIRST (e.g., 1-12/3 or */3)
            if (part.Contains('/'))
            {
                var slashIdx = part.IndexOf('/');
                var rangePart = part[..slashIdx];
                var stepStr = part[(slashIdx + 1)..];

                int start, end;
                if (rangePart == "*")
                {
                    start = 1;
                    end = 12;
                }
                else if (rangePart.Contains('-'))
                {
                    var dashIdx = rangePart.IndexOf('-');
                    var startMonth = ParseMonthValue(rangePart[..dashIdx]);
                    var endMonth = ParseMonthValue(rangePart[(dashIdx + 1)..]);
                    start = startMonth.Number();
                    end = endMonth.Number();
                }
                else
                {
                    throw HronException.Cron($"invalid month step expression: {part}");
                }

                if (!int.TryParse(stepStr, out var step) || step == 0)
                {
                    throw HronException.Cron($"invalid month step value: {stepStr}");
                }

                for (var n = start; n <= end; n += step)
                {
                    months.Add(MonthFromNumber(n));
                }
            }
            else if (part.Contains('-'))
            {
                // Range like 1-3 or JAN-MAR
                var dashIdx = part.IndexOf('-');
                var startMonth = ParseMonthValue(part[..dashIdx]);
                var endMonth = ParseMonthValue(part[(dashIdx + 1)..]);
                var startNum = startMonth.Number();
                var endNum = endMonth.Number();

                if (startNum > endNum)
                {
                    throw HronException.Cron($"invalid month range: {part}");
                }

                for (var n = startNum; n <= endNum; n++)
                {
                    months.Add(MonthFromNumber(n));
                }
            }
            else
            {
                // Single month
                months.Add(ParseMonthValue(part));
            }
        }

        return months;
    }

    /// <summary>
    /// Parse a single month value (number 1-12 or name JAN-DEC).
    /// </summary>
    private static MonthName ParseMonthValue(string s)
    {
        // Try as number first
        if (int.TryParse(s, out var n))
        {
            return MonthFromNumber(n);
        }
        // Try as name
        var month = MonthNameExtensions.Parse(s);
        if (month is null)
        {
            throw HronException.Cron($"invalid month: {s}");
        }
        return month.Value;
    }

    private static MonthName MonthFromNumber(int n)
    {
        var month = MonthNameExtensions.FromNumber(n);
        if (month is null)
        {
            throw HronException.Cron($"invalid month number: {n}");
        }
        return month.Value;
    }

    /// <summary>
    /// Try to parse nth weekday patterns like 1#1 (first Monday) or 5L (last Friday).
    /// </summary>
    private static ScheduleData? TryParseNthWeekday(
        string minuteField,
        string hourField,
        string domField,
        string dowField,
        List<MonthName> during)
    {
        // Check for # pattern (nth weekday of month)
        if (dowField.Contains('#'))
        {
            var hashIdx = dowField.IndexOf('#');
            var dowStr = dowField[..hashIdx];
            var nthStr = dowField[(hashIdx + 1)..];

            var dowNum = ParseDowValue(dowStr);
            var weekday = CronDOWToWeekday(dowNum);

            if (!int.TryParse(nthStr, out var nth) || nth < 1 || nth > 5)
            {
                throw HronException.Cron($"nth must be 1-5, got {nthStr}");
            }

            var ordinal = nth switch
            {
                1 => OrdinalPosition.First,
                2 => OrdinalPosition.Second,
                3 => OrdinalPosition.Third,
                4 => OrdinalPosition.Fourth,
                5 => OrdinalPosition.Fifth,
                _ => throw HronException.Cron($"invalid nth value: {nth}")
            };

            if (domField != "*" && domField != "?")
            {
                throw HronException.Cron("DOM must be * when using # for nth weekday");
            }

            var minute = ParseSingleValue(minuteField, "minute", 0, 59);
            var hour = ParseSingleValue(hourField, "hour", 0, 23);

            return ScheduleData.Of(new OrdinalRepeat(1, ordinal, weekday, [new TimeOfDay(hour, minute)]))
                .WithDuring(during);
        }

        // Check for nL pattern (last weekday of month, e.g., 5L = last Friday)
        if (dowField.EndsWith('L') && dowField.Length > 1)
        {
            var dowStr = dowField[..^1];
            var dowNum = ParseDowValue(dowStr);
            var weekday = CronDOWToWeekday(dowNum);

            if (domField != "*" && domField != "?")
            {
                throw HronException.Cron("DOM must be * when using nL for last weekday");
            }

            var minute = ParseSingleValue(minuteField, "minute", 0, 59);
            var hour = ParseSingleValue(hourField, "hour", 0, 23);

            return ScheduleData.Of(new OrdinalRepeat(1, OrdinalPosition.Last, weekday, [new TimeOfDay(hour, minute)]))
                .WithDuring(during);
        }

        return null;
    }

    /// <summary>
    /// Try to parse L (last day) or LW (last weekday) patterns.
    /// </summary>
    private static ScheduleData? TryParseLastDay(
        string minuteField,
        string hourField,
        string domField,
        string dowField,
        List<MonthName> during)
    {
        if (domField != "L" && domField != "LW")
        {
            return null;
        }

        if (dowField != "*" && dowField != "?")
        {
            throw HronException.Cron("DOW must be * when using L or LW in DOM");
        }

        var minute = ParseSingleValue(minuteField, "minute", 0, 59);
        var hour = ParseSingleValue(hourField, "hour", 0, 23);

        var target = domField == "LW" ? MonthTarget.LastWeekday() : MonthTarget.LastDay();

        return ScheduleData.Of(new MonthRepeat(1, target, [new TimeOfDay(hour, minute)]))
            .WithDuring(during);
    }

    /// <summary>
    /// Try to parse interval patterns: */N, range/N in minute or hour fields.
    /// </summary>
    private static ScheduleData? TryParseInterval(
        string minuteField,
        string hourField,
        string domField,
        string dowField,
        List<MonthName> during)
    {
        // Minute interval: */N or range/N
        if (minuteField.Contains('/'))
        {
            var slashIdx = minuteField.IndexOf('/');
            var rangePart = minuteField[..slashIdx];
            var stepStr = minuteField[(slashIdx + 1)..];

            if (!int.TryParse(stepStr, out var interval) || interval == 0)
            {
                throw HronException.Cron("invalid minute interval value");
            }

            int fromMinute, toMinute;
            if (rangePart == "*")
            {
                fromMinute = 0;
                toMinute = 59;
            }
            else if (rangePart.Contains('-'))
            {
                var dashIdx = rangePart.IndexOf('-');
                if (!int.TryParse(rangePart[..dashIdx], out fromMinute) ||
                    !int.TryParse(rangePart[(dashIdx + 1)..], out toMinute))
                {
                    throw HronException.Cron("invalid minute range");
                }
                if (fromMinute > toMinute)
                {
                    throw HronException.Cron($"range start must be <= end: {fromMinute}-{toMinute}");
                }
            }
            else
            {
                // Single value with step (e.g., 0/15) - treat as starting point
                if (!int.TryParse(rangePart, out fromMinute))
                {
                    throw HronException.Cron("invalid minute value");
                }
                toMinute = 59;
            }

            // Determine the hour window
            int fromHour, toHour;
            if (hourField == "*")
            {
                fromHour = 0;
                toHour = 23;
            }
            else if (hourField.Contains('-'))
            {
                var dashIdx = hourField.IndexOf('-');
                if (!int.TryParse(hourField[..dashIdx], out fromHour) ||
                    !int.TryParse(hourField[(dashIdx + 1)..], out toHour))
                {
                    throw HronException.Cron("invalid hour range");
                }
            }
            else if (hourField.Contains('/'))
            {
                // Hour also has step - this is complex, handle as hour interval
                return null;
            }
            else
            {
                if (!int.TryParse(hourField, out fromHour))
                {
                    throw HronException.Cron("invalid hour");
                }
                toHour = fromHour;
            }

            // Check if this should be a day filter
            DayFilter? dayFilter = null;
            if (dowField != "*")
            {
                dayFilter = ParseCronDOW(dowField);
            }

            if (domField == "*" || domField == "?")
            {
                // Determine the end minute based on context
                int endMinute;
                if (fromMinute == 0 && toMinute == 59 && toHour == 23)
                {
                    // Full day: 00:00 to 23:59
                    endMinute = 59;
                }
                else if (fromMinute == 0 && toMinute == 59)
                {
                    // Partial day with full minutes range: use :00 for cleaner output
                    endMinute = 0;
                }
                else
                {
                    endMinute = toMinute;
                }

                return ScheduleData.Of(new IntervalRepeat(
                    interval,
                    IntervalUnit.Minutes,
                    new TimeOfDay(fromHour, fromMinute),
                    new TimeOfDay(toHour, endMinute),
                    dayFilter)).WithDuring(during);
            }
        }

        // Hour interval: 0 */N or 0 range/N
        if (hourField.Contains('/') && (minuteField == "0" || minuteField == "00"))
        {
            var slashIdx = hourField.IndexOf('/');
            var rangePart = hourField[..slashIdx];
            var stepStr = hourField[(slashIdx + 1)..];

            if (!int.TryParse(stepStr, out var interval) || interval == 0)
            {
                throw HronException.Cron("invalid hour interval value");
            }

            int fromHour, toHour;
            if (rangePart == "*")
            {
                fromHour = 0;
                toHour = 23;
            }
            else if (rangePart.Contains('-'))
            {
                var dashIdx = rangePart.IndexOf('-');
                if (!int.TryParse(rangePart[..dashIdx], out fromHour) ||
                    !int.TryParse(rangePart[(dashIdx + 1)..], out toHour))
                {
                    throw HronException.Cron("invalid hour range");
                }
                if (fromHour > toHour)
                {
                    throw HronException.Cron($"range start must be <= end: {fromHour}-{toHour}");
                }
            }
            else
            {
                if (!int.TryParse(rangePart, out fromHour))
                {
                    throw HronException.Cron("invalid hour value");
                }
                toHour = 23;
            }

            if ((domField == "*" || domField == "?") && (dowField == "*" || dowField == "?"))
            {
                // Use :59 only for full day (00:00 to 23:59), otherwise use :00
                var endMinute = (fromHour == 0 && toHour == 23) ? 59 : 0;

                return ScheduleData.Of(new IntervalRepeat(
                    interval,
                    IntervalUnit.Hours,
                    new TimeOfDay(fromHour, 0),
                    new TimeOfDay(toHour, endMinute),
                    null)).WithDuring(during);
            }
        }

        return null;
    }

    /// <summary>
    /// Parse a DOM field into a MonthTarget.
    /// </summary>
    private static MonthTarget ParseDomField(string field)
    {
        var specs = new List<DayOfMonthSpec>();

        foreach (var part in field.Split(','))
        {
            if (part.Contains('/'))
            {
                // Step value: 1-31/2 or */5
                var slashIdx = part.IndexOf('/');
                var rangePart = part[..slashIdx];
                var stepStr = part[(slashIdx + 1)..];

                int start, end;
                if (rangePart == "*")
                {
                    start = 1;
                    end = 31;
                }
                else if (rangePart.Contains('-'))
                {
                    var dashIdx = rangePart.IndexOf('-');
                    if (!int.TryParse(rangePart[..dashIdx], out start))
                    {
                        throw HronException.Cron($"invalid DOM range start: {rangePart[..dashIdx]}");
                    }
                    if (!int.TryParse(rangePart[(dashIdx + 1)..], out end))
                    {
                        throw HronException.Cron($"invalid DOM range end: {rangePart[(dashIdx + 1)..]}");
                    }
                    if (start > end)
                    {
                        throw HronException.Cron($"range start must be <= end: {start}-{end}");
                    }
                }
                else
                {
                    if (!int.TryParse(rangePart, out start))
                    {
                        throw HronException.Cron($"invalid DOM value: {rangePart}");
                    }
                    end = 31;
                }

                if (!int.TryParse(stepStr, out var step) || step == 0)
                {
                    throw HronException.Cron($"invalid DOM step: {stepStr}");
                }

                ValidateDom(start);
                ValidateDom(end);

                for (var d = start; d <= end; d += step)
                {
                    specs.Add(DayOfMonthSpec.Single(d));
                }
            }
            else if (part.Contains('-'))
            {
                // Range: 1-5
                var dashIdx = part.IndexOf('-');
                if (!int.TryParse(part[..dashIdx], out var start))
                {
                    throw HronException.Cron($"invalid DOM range start: {part[..dashIdx]}");
                }
                if (!int.TryParse(part[(dashIdx + 1)..], out var end))
                {
                    throw HronException.Cron($"invalid DOM range end: {part[(dashIdx + 1)..]}");
                }
                if (start > end)
                {
                    throw HronException.Cron($"range start must be <= end: {start}-{end}");
                }
                ValidateDom(start);
                ValidateDom(end);
                specs.Add(DayOfMonthSpec.Range(start, end));
            }
            else
            {
                // Single: 15
                if (!int.TryParse(part, out var day))
                {
                    throw HronException.Cron($"invalid DOM value: {part}");
                }
                ValidateDom(day);
                specs.Add(DayOfMonthSpec.Single(day));
            }
        }

        return MonthTarget.Days(specs);
    }

    private static void ValidateDom(int day)
    {
        if (day < 1 || day > 31)
        {
            throw HronException.Cron($"DOM must be 1-31, got {day}");
        }
    }

    /// <summary>
    /// Parse a DOW field into a DayFilter.
    /// </summary>
    private static DayFilter ParseCronDOW(string field)
    {
        if (field == "*")
        {
            return DayFilter.Every();
        }

        var days = new List<Weekday>();

        foreach (var part in field.Split(','))
        {
            if (part.Contains('/'))
            {
                // Step value: 0-6/2 or */2
                var slashIdx = part.IndexOf('/');
                var rangePart = part[..slashIdx];
                var stepStr = part[(slashIdx + 1)..];

                int start, end;
                if (rangePart == "*")
                {
                    start = 0;
                    end = 6;
                }
                else if (rangePart.Contains('-'))
                {
                    var dashIdx = rangePart.IndexOf('-');
                    start = ParseDowValueRaw(rangePart[..dashIdx]);
                    end = ParseDowValueRaw(rangePart[(dashIdx + 1)..]);
                    if (start > end)
                    {
                        throw HronException.Cron($"range start must be <= end: {rangePart}");
                    }
                }
                else
                {
                    start = ParseDowValueRaw(rangePart);
                    end = 6;
                }

                if (!int.TryParse(stepStr, out var step) || step == 0)
                {
                    throw HronException.Cron($"invalid DOW step: {stepStr}");
                }

                for (var d = start; d <= end; d += step)
                {
                    days.Add(CronDOWToWeekday(d));
                }
            }
            else if (part.Contains('-'))
            {
                // Range: 1-5 or MON-FRI
                var dashIdx = part.IndexOf('-');
                // Parse without normalizing 7 to 0 for range purposes
                var start = ParseDowValueRaw(part[..dashIdx]);
                var end = ParseDowValueRaw(part[(dashIdx + 1)..]);
                if (start > end)
                {
                    throw HronException.Cron($"range start must be <= end: {part}");
                }
                for (var d = start; d <= end; d++)
                {
                    // Normalize 7 to 0 (Sunday) when converting to weekday
                    var normalized = d == 7 ? 0 : d;
                    days.Add(CronDOWToWeekday(normalized));
                }
            }
            else
            {
                // Single: 1 or MON
                var dow = ParseDowValue(part);
                days.Add(CronDOWToWeekday(dow));
            }
        }

        // Check for special patterns
        if (days.Count == 5)
        {
            var sorted = days.OrderBy(d => d.Number()).ToList();
            var weekdays = new List<Weekday>
            {
                Weekday.Monday, Weekday.Tuesday, Weekday.Wednesday,
                Weekday.Thursday, Weekday.Friday
            };
            if (sorted.SequenceEqual(weekdays))
            {
                return DayFilter.Weekday();
            }
        }
        if (days.Count == 2)
        {
            var sorted = days.OrderBy(d => d.Number()).ToList();
            var weekend = new List<Weekday> { Weekday.Saturday, Weekday.Sunday };
            if (sorted.SequenceEqual(weekend))
            {
                return DayFilter.Weekend();
            }
        }

        return DayFilter.SpecificDays(days);
    }

    /// <summary>
    /// Parse a DOW value (number 0-7 or name SUN-SAT), normalizing 7 to 0.
    /// </summary>
    private static int ParseDowValue(string s)
    {
        var raw = ParseDowValueRaw(s);
        // Normalize 7 to 0 (both mean Sunday)
        return raw == 7 ? 0 : raw;
    }

    /// <summary>
    /// Parse a DOW value without normalizing 7 to 0 (for range checking).
    /// </summary>
    private static int ParseDowValueRaw(string s)
    {
        // Try as number first
        if (int.TryParse(s, out var n))
        {
            if (n > 7)
            {
                throw HronException.Cron($"DOW must be 0-7, got {n}");
            }
            return n;
        }
        // Try as name
        return s.ToUpperInvariant() switch
        {
            "SUN" => 0,
            "MON" => 1,
            "TUE" => 2,
            "WED" => 3,
            "THU" => 4,
            "FRI" => 5,
            "SAT" => 6,
            _ => throw HronException.Cron($"invalid DOW: {s}")
        };
    }

    private static Weekday CronDOWToWeekday(int n) => n switch
    {
        0 or 7 => Weekday.Sunday,
        1 => Weekday.Monday,
        2 => Weekday.Tuesday,
        3 => Weekday.Wednesday,
        4 => Weekday.Thursday,
        5 => Weekday.Friday,
        6 => Weekday.Saturday,
        _ => throw HronException.Cron($"invalid DOW number: {n}")
    };

    /// <summary>
    /// Parse a single numeric value with validation.
    /// </summary>
    private static int ParseSingleValue(string field, string name, int min, int max)
    {
        if (!int.TryParse(field, out var value))
        {
            throw HronException.Cron($"invalid {name} field: {field}");
        }
        if (value < min || value > max)
        {
            throw HronException.Cron($"{name} must be {min}-{max}, got {value}");
        }
        return value;
    }
}
