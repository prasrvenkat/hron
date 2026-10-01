using System.Text;
using Hron.Ast;
using Hron.Eval;

namespace Hron.Cron;

public static class CronConverter
{
    private const int MaxListedTimes = 24;
    private const string BothDaysRestricted =
        "not expressible in hron: cron fires on either the day of month or the day of week";
    private const string IntervalDays =
        "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";
    private const int MinutesPerDay = 24 * 60;
    private static readonly TimeOfDay Midnight = new(0, 0);
    private static readonly TimeOfDay EndOfDay = new(23, 59);

    // Digit strings may be of any length. Every number at or above this cap is out
    // of every field's range and steps past every range's end, so saturating at it
    // keeps each comparison exact without overflow.
    private const int NumberCap = 1000;

    private static readonly string[] MonthNames =
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
    private static readonly string[] DayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    private static readonly Weekday[] Weekdays =
    [
        Weekday.Sunday, Weekday.Monday, Weekday.Tuesday, Weekday.Wednesday,
        Weekday.Thursday, Weekday.Friday, Weekday.Saturday
    ];
    private static readonly OrdinalPosition[] Ordinals =
    [
        OrdinalPosition.First, OrdinalPosition.Second, OrdinalPosition.Third,
        OrdinalPosition.Fourth, OrdinalPosition.Fifth
    ];

    // In the day of week, 7 is Sunday only where written: `*` and `a/n` end at 6.
    private sealed record Field(string Name, int Min, int Max, int StarEnd, string[] Names)
    {
        public static readonly Field Minute = new("minute", 0, 59, 59, []);
        public static readonly Field Hour = new("hour", 0, 23, 23, []);
        public static readonly Field DayOfMonth = new("day of month", 1, 31, 31, []);
        public static readonly Field Month = new("month", 1, 12, 12, MonthNames);
        public static readonly Field DayOfWeek = new("day of week", 0, 7, 6, DayNames);
    }

    private abstract record Bounds
    {
        public sealed record Star : Bounds;

        public sealed record Value(string A) : Bounds;

        public sealed record Range(string A, string B) : Bounds;
    }

    private sealed record Item(Bounds Bounds, string? Step);

    private abstract record MonthDays
    {
        public sealed record Any : MonthDays;

        public sealed record Listed(List<int> Days) : MonthDays;

        public sealed record Last : MonthDays;

        public sealed record LastWeekday : MonthDays;

        public sealed record Nearest(int Day) : MonthDays;
    }

    private abstract record WeekDays
    {
        public sealed record Any : WeekDays;

        public sealed record Listed(List<int> Days) : WeekDays;

        public sealed record Nth(Weekday Weekday, int N) : WeekDays;

        public sealed record Last(Weekday Weekday) : WeekDays;
    }

    private abstract record Days
    {
        public sealed record OfWeek(DayFilter Filter) : Days;

        public sealed record OfMonth(MonthTarget Target) : Days;
    }

    public static ScheduleData FromCron(string cron)
    {
        var input = cron.Trim(' ', '\t', '\r', '\n');
        var text = input.StartsWith('@') ? Shortcut(input) : input;
        var fields = text.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        if (fields.Length != 5)
        {
            throw HronException.Cron($"expected 5 cron fields, got {fields.Length}");
        }

        var minutes = Sorted(Values(fields[0], Field.Minute));
        var hours = Sorted(Values(fields[1], Field.Hour));
        var monthDays = ParseDayOfMonth(fields[2]);
        var months = Sorted(Values(fields[3], Field.Month));
        var weekDays = ParseDayOfWeek(fields[4]);
        var days = DayExpression(monthDays, weekDays);
        var times = hours.SelectMany(hour => minutes.Select(minute => new TimeOfDay(hour, minute))).ToList();

        var gap = EqualGap(times);
        IScheduleExpr expr;
        if (days is Days.OfWeek ofWeek && gap is { } equalGap)
        {
            expr = Interval(times, equalGap, ofWeek.Filter);
        }
        else if (times.Count > MaxListedTimes)
        {
            throw TooManyTimes(times.Count, gap);
        }
        else if (YearlyTarget(days, months) is { } target)
        {
            expr = new YearRepeat(1, target, times);
        }
        else if (days is Days.OfWeek everyWeek)
        {
            expr = new DayRepeat(1, everyWeek.Filter, times);
        }
        else
        {
            expr = new MonthRepeat(1, ((Days.OfMonth)days).Target, times);
        }

        var schedule = ScheduleData.Of(expr);
        if (expr is not YearRepeat && months.Count < MonthNames.Length)
        {
            schedule = schedule.WithDuring(months.Select(m => (MonthName)m).ToList());
        }
        return schedule;
    }

    private static string Shortcut(string input)
    {
        if (Ascii.EqualsIgnoreCase(input, "@yearly") || Ascii.EqualsIgnoreCase(input, "@annually"))
        {
            return "0 0 1 1 *";
        }
        if (Ascii.EqualsIgnoreCase(input, "@monthly"))
        {
            return "0 0 1 * *";
        }
        if (Ascii.EqualsIgnoreCase(input, "@weekly"))
        {
            return "0 0 * * 0";
        }
        if (Ascii.EqualsIgnoreCase(input, "@daily") || Ascii.EqualsIgnoreCase(input, "@midnight"))
        {
            return "0 0 * * *";
        }
        if (Ascii.EqualsIgnoreCase(input, "@hourly"))
        {
            return "0 * * * *";
        }
        throw HronException.Cron($"unknown cron shortcut: {input}");
    }

    private static MonthDays ParseDayOfMonth(string text)
    {
        if (text is "*" or "?")
        {
            return new MonthDays.Any();
        }
        if (Ascii.EqualsIgnoreCase(text, "L"))
        {
            return new MonthDays.Last();
        }
        if (Ascii.EqualsIgnoreCase(text, "LW"))
        {
            return new MonthDays.LastWeekday();
        }
        if (text.EndsWith('W') || text.EndsWith('w'))
        {
            var day = text[..^1];
            if (IsNumber(day))
            {
                return new MonthDays.Nearest(FieldValue(day, Field.DayOfMonth));
            }
        }
        return new MonthDays.Listed(Values(text, Field.DayOfMonth));
    }

    private static WeekDays ParseDayOfWeek(string text)
    {
        var field = Field.DayOfWeek;
        if (text is "*" or "?")
        {
            return new WeekDays.Any();
        }
        var hash = text.IndexOf('#');
        if (hash >= 0)
        {
            var day = text[..hash];
            var nth = text[(hash + 1)..];
            if (IsValue(day, field) && IsNumber(nth))
            {
                var weekday = Weekdays[FieldValue(day, field) % 7];
                var n = Number(nth);
                if (n < 1 || n > 5)
                {
                    throw HronException.Cron($"day of week ordinal must be 1-5, got {nth}");
                }
                return new WeekDays.Nth(weekday, n);
            }
        }
        if (text.EndsWith('L') || text.EndsWith('l'))
        {
            var day = text[..^1];
            if (IsValue(day, field))
            {
                return new WeekDays.Last(Weekdays[FieldValue(day, field) % 7]);
            }
        }
        return new WeekDays.Listed(Values(text, field));
    }

    // Keeps the order of first appearance, in which fromCron lists days of the week.
    private static List<int> Values(string text, Field field)
    {
        var items = Items(text, field) ?? throw HronException.Cron($"invalid {field.Name}: {text}");
        var values = new List<int>();
        foreach (var item in items)
        {
            int first;
            int last;
            switch (item.Bounds)
            {
                case Bounds.Value value:
                    first = FieldValue(value.A, field);
                    // `7/n` starts past the end of `*`, so it is Sunday alone.
                    last = item.Step is null ? first : Math.Max(first, field.StarEnd);
                    break;
                case Bounds.Range range:
                    first = FieldValue(range.A, field);
                    last = FieldValue(range.B, field);
                    if (first > last)
                    {
                        throw HronException.Cron($"{field.Name} range must not run backwards: {range.A}-{range.B}");
                    }
                    break;
                default:
                    first = field.Min;
                    last = field.StarEnd;
                    break;
            }
            var step = item.Step is null ? 1 : Number(item.Step);
            if (step == 0)
            {
                throw HronException.Cron($"{field.Name} step must be at least 1");
            }
            for (var n = first; n <= last; n += step)
            {
                var value = field == Field.DayOfWeek ? n % 7 : n;
                if (!values.Contains(value))
                {
                    values.Add(value);
                }
            }
        }
        return values;
    }

    private static List<Item>? Items(string text, Field field)
    {
        var items = new List<Item>();
        foreach (var item in text.Split(','))
        {
            var slash = item.IndexOf('/');
            var range = slash < 0 ? item : item[..slash];
            var step = slash < 0 ? null : item[(slash + 1)..];
            var dash = range.IndexOf('-');
            Bounds bounds = range == "*" ? new Bounds.Star()
                : dash >= 0 ? new Bounds.Range(range[..dash], range[(dash + 1)..])
                : new Bounds.Value(range);
            var valid = (step is null || IsNumber(step)) && bounds switch
            {
                Bounds.Value value => IsValue(value.A, field),
                Bounds.Range r => IsValue(r.A, field) && IsValue(r.B, field),
                _ => true
            };
            if (!valid)
            {
                return null;
            }
            items.Add(new Item(bounds, step));
        }
        return items;
    }

    private static bool IsNumber(string text) => text.Length > 0 && text.All(char.IsAsciiDigit);

    private static bool IsValue(string text, Field field) => IsNumber(text) || NameValue(text, field) is not null;

    private static int? NameValue(string text, Field field)
    {
        var index = Array.FindIndex(field.Names, name => Ascii.EqualsIgnoreCase(name, text));
        return index < 0 ? null : index + field.Min;
    }

    private static int Number(string digits)
    {
        var n = 0;
        foreach (var digit in digits)
        {
            n = Math.Min(n * 10 + (digit - '0'), NumberCap);
        }
        return n;
    }

    private static int FieldValue(string text, Field field)
    {
        var value = NameValue(text, field) ?? Number(text);
        if (value < field.Min || value > field.Max)
        {
            throw HronException.Cron($"{field.Name} must be {field.Min}-{field.Max}, got {text}");
        }
        return value;
    }

    private static Days DayExpression(MonthDays monthDays, WeekDays weekDays) => (monthDays, weekDays) switch
    {
        (MonthDays.Any, WeekDays.Any) => new Days.OfWeek(DayFilter.Every()),
        (MonthDays.Any, WeekDays.Listed listed) => new Days.OfWeek(WeekdayFilter(listed.Days)),
        (MonthDays.Any, WeekDays.Nth nth) =>
            new Days.OfMonth(MonthTarget.OrdinalWeekday(Ordinals[nth.N - 1], nth.Weekday)),
        (MonthDays.Any, WeekDays.Last last) =>
            new Days.OfMonth(MonthTarget.OrdinalWeekday(OrdinalPosition.Last, last.Weekday)),
        (MonthDays.Listed listed, WeekDays.Any) when listed.Days.Count == 31 => new Days.OfWeek(DayFilter.Every()),
        (MonthDays.Listed listed, WeekDays.Any) => new Days.OfMonth(MonthTarget.Days(
            Runs(Sorted(listed.Days))
                .Select(run => run.First == run.Last
                    ? DayOfMonthSpec.Single(run.First)
                    : DayOfMonthSpec.Range(run.First, run.Last))
                .ToList())),
        (MonthDays.Last, WeekDays.Any) => new Days.OfMonth(MonthTarget.LastDay()),
        (MonthDays.LastWeekday, WeekDays.Any) => new Days.OfMonth(MonthTarget.LastWeekday()),
        (MonthDays.Nearest nearest, WeekDays.Any) =>
            new Days.OfMonth(MonthTarget.NearestWeekday(nearest.Day, direction: null)),
        _ => throw HronException.Cron(BothDaysRestricted)
    };

    private static DayFilter WeekdayFilter(List<int> days)
    {
        var sorted = Sorted(days);
        if (sorted.SequenceEqual([0, 1, 2, 3, 4, 5, 6]))
        {
            return DayFilter.Every();
        }
        if (sorted.SequenceEqual([1, 2, 3, 4, 5]))
        {
            return DayFilter.Weekday();
        }
        if (sorted.SequenceEqual([0, 6]))
        {
            return DayFilter.Weekend();
        }
        return DayFilter.SpecificDays(days.Select(d => Weekdays[d]).ToList());
    }

    private static int? EqualGap(List<TimeOfDay> times)
    {
        if (times.Count < 2)
        {
            return null;
        }
        var minutes = times.Select(t => t.TotalMinutes).ToList();
        var gap = minutes[1] - minutes[0];
        var equal = minutes.Count >= 3 && minutes.Zip(minutes.Skip(1)).All(w => w.Second - w.First == gap);
        return equal ? gap : null;
    }

    private static IntervalRepeat Interval(List<TimeOfDay> times, int gap, DayFilter days)
    {
        var from = times[0];
        var last = times[^1];
        var to = from == Midnight && last.TotalMinutes + gap >= MinutesPerDay ? EndOfDay : last;
        var (interval, unit) = gap % 60 == 0 ? (gap / 60, IntervalUnit.Hours) : (gap, IntervalUnit.Minutes);
        return new IntervalRepeat(interval, unit, from, to, days.Kind == DayFilterKind.Every ? null : days);
    }

    private static HronException TooManyTimes(int count, int? gap) => gap is null
        ? HronException.Cron($"not expressible in hron: {count} times a day are too many to list")
        : HronException.Cron(IntervalDays);

    private static YearTarget? YearlyTarget(Days days, List<int> months)
    {
        if (days is not Days.OfMonth { Target: var target } || months.Count != 1)
        {
            return null;
        }
        var month = (MonthName)months[0];
        return target.Kind switch
        {
            MonthTargetKind.Days when target.Specs is [{ Kind: DayOfMonthSpecKind.Single } spec]
                && spec.Day <= MaxDay(month) => YearTarget.Date(month, spec.Day),
            MonthTargetKind.LastWeekday => YearTarget.LastWeekday(month),
            MonthTargetKind.OrdinalWeekday => YearTarget.OrdinalWeekday(
                target.OrdinalValue!.Value, target.WeekdayValue!.Value, month),
            _ => null
        };
    }

    private static int MaxDay(MonthName month) => month switch
    {
        MonthName.February => 29,
        MonthName.April or MonthName.June or MonthName.September or MonthName.November => 30,
        _ => 31
    };

    public static string ToCron(ScheduleData data)
    {
        if (data.Except.Count > 0)
        {
            throw NotExpressible("except clauses not supported");
        }
        if (data.Until is not null)
        {
            throw NotExpressible("until clauses not supported");
        }
        if (data.Anchor is not null)
        {
            throw NotExpressible("starting clauses not supported");
        }
        var (dayOfMonth, dayOfWeek) = DayFields(data.Expr);
        // ScheduleData can hold an empty day list, which writes an empty field.
        if (dayOfMonth.Length == 0 || dayOfWeek.Length == 0)
        {
            throw NotExpressible("schedule has no days");
        }
        var month = MonthField(data);
        var (minute, hour) = TimeFields(data.Expr);
        return $"{minute} {hour} {dayOfMonth} {month} {dayOfWeek}";
    }

    private static HronException NotExpressible(string reason) =>
        HronException.Cron($"not expressible as cron: {reason}");

    private static void RepeatsOnce(int interval, string unit)
    {
        if (interval > 1)
        {
            throw NotExpressible($"multi-{unit} repeats not supported");
        }
    }

    private static (string DayOfMonth, string DayOfWeek) DayFields(IScheduleExpr expr)
    {
        const string any = "*";
        switch (expr)
        {
            case IntervalRepeat ir:
                return (any, ir.DayFilter is null ? any : FilterField(ir.DayFilter));
            case DayRepeat dr:
                RepeatsOnce(dr.Interval, "day");
                return (any, FilterField(dr.Days));
            case WeekRepeat wr:
                RepeatsOnce(wr.Interval, "week");
                return (any, WeekdaysField(wr.WeekDays));
            case MonthRepeat mr:
                RepeatsOnce(mr.Interval, "month");
                var target = mr.Target;
                return target.Kind switch
                {
                    MonthTargetKind.Days => (ListField(SortedUnique(target.ExpandDays()), 31), any),
                    MonthTargetKind.LastDay => ("L", any),
                    MonthTargetKind.LastWeekday => ("LW", any),
                    MonthTargetKind.NearestWeekday when target.NearestWeekdayDirection is not null =>
                        throw NotExpressible("directional nearest weekday not supported"),
                    MonthTargetKind.NearestWeekday => ($"{target.NearestWeekdayDay}W", any),
                    _ => (any, OrdinalField(target.OrdinalValue!.Value, target.WeekdayValue!.Value))
                };
            case YearRepeat yr:
                RepeatsOnce(yr.Interval, "year");
                return yr.Target.Kind switch
                {
                    YearTargetKind.Date or YearTargetKind.DayOfMonth => (yr.Target.Day.ToString(), any),
                    YearTargetKind.OrdinalWeekday =>
                        (any, OrdinalField(yr.Target.Ordinal!.Value, yr.Target.WeekdayValue!.Value)),
                    _ => ("LW", any)
                };
            case SingleDate { DateSpec.Kind: DateSpecKind.Iso }:
                throw NotExpressible("ISO dates do not repeat");
            case SingleDate sd:
                return (sd.DateSpec.Day.ToString(), any);
            default:
                throw new ArgumentException($"Unknown expression type: {expr.GetType()}", nameof(expr));
        }
    }

    private static string MonthField(ScheduleData data)
    {
        var during = data.During;
        if (OwnMonth(data.Expr) is { } month)
        {
            if (during.Count > 0 && !during.Contains(month))
            {
                throw NotExpressible("during excludes the schedule's month");
            }
            return month.Number().ToString();
        }
        return during.Count == 0 ? "*" : ListField(SortedUnique(during.Select(m => m.Number())), 12);
    }

    private static MonthName? OwnMonth(IScheduleExpr expr) => expr switch
    {
        YearRepeat yr => yr.Target.Month,
        SingleDate { DateSpec.Kind: DateSpecKind.Named } sd => sd.DateSpec.Month,
        _ => null
    };

    private static (string Minute, string Hour) TimeFields(IScheduleExpr expr)
    {
        var times = DailyMinutes(expr);
        var minutes = SortedUnique(times.Select(t => (int)(t % 60)));
        var hours = SortedUnique(times.Select(t => (int)(t / 60)));
        // ScheduleData can hold a schedule with no times, which no cron writes.
        if (times.Count == 0)
        {
            throw NotExpressible("schedule has no times");
        }
        if (minutes.Count * hours.Count != times.Count)
        {
            throw NotExpressible("times are not every combination of their minutes and hours");
        }
        return (StepField(minutes, 60), StepField(hours, 24));
    }

    private static List<long> DailyMinutes(IScheduleExpr expr)
    {
        IEnumerable<long> times = DailyTimes.Of(expr) switch
        {
            DailyTimes.Slots slots => LongRange(slots.Count).Select(slots.MinuteAt),
            DailyTimes.Fixed fixedTimes => fixedTimes.Times.Select(t => (long)t.TotalMinutes),
            _ => []
        };
        return times.Distinct().Order().ToList();
    }

    private static IEnumerable<long> LongRange(long count)
    {
        for (long i = 0; i < count; i++)
        {
            yield return i;
        }
    }

    private static string FilterField(DayFilter filter) => filter.Kind switch
    {
        DayFilterKind.Every => "*",
        DayFilterKind.Weekday => WeekdaysField(
            [Weekday.Monday, Weekday.Tuesday, Weekday.Wednesday, Weekday.Thursday, Weekday.Friday]),
        DayFilterKind.Weekend => WeekdaysField([Weekday.Saturday, Weekday.Sunday]),
        _ => WeekdaysField(filter.Days)
    };

    private static string WeekdaysField(IReadOnlyList<Weekday> days) =>
        ListField(SortedUnique(days.Select(d => d.CronDOW())), 7);

    private static string OrdinalField(OrdinalPosition ordinal, Weekday weekday)
    {
        var day = weekday.CronDOW();
        var index = Array.IndexOf(Ordinals, ordinal);
        return index >= 0 ? $"{day}#{index + 1}" : $"{day}L";
    }

    private static string StepField(List<int> values, int size)
    {
        var first = values[0];
        var last = values[^1];
        int? gap = values.Count > 1 ? values[1] - first : null;
        var equalGaps = gap is not null && values.Zip(values.Skip(1)).All(w => w.Second - w.First == gap);
        if (values.Count == size)
        {
            return "*";
        }
        if (gap is null)
        {
            return first.ToString();
        }
        if (equalGaps && first == 0 && last + gap == size)
        {
            return $"*/{gap}";
        }
        if (equalGaps && gap == 1)
        {
            return $"{first}-{last}";
        }
        if (equalGaps && values.Count >= 3)
        {
            return $"{first}-{last}/{gap}";
        }
        return ListField(values, size);
    }

    private static string ListField(List<int> values, int size)
    {
        if (values.Count == size)
        {
            return "*";
        }
        return string.Join(",", Runs(values).Select(run => run.First == run.Last
            ? run.First.ToString()
            : $"{run.First}-{run.Last}"));
    }

    private static List<(int First, int Last)> Runs(List<int> sortedValues)
    {
        var runs = new List<(int First, int Last)>();
        foreach (var value in sortedValues)
        {
            if (runs.Count > 0 && runs[^1].Last + 1 == value)
            {
                runs[^1] = (runs[^1].First, value);
            }
            else
            {
                runs.Add((value, value));
            }
        }
        return runs;
    }

    private static List<int> Sorted(List<int> values) => values.Order().ToList();

    private static List<int> SortedUnique(IEnumerable<int> values) => values.Distinct().Order().ToList();
}
