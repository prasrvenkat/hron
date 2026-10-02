using System.Globalization;
using Xunit;

namespace Hron.Tests;

public class CronPropertyTest
{
    // Two years around 2044-02-29, a leap day in a February with five Mondays.
    private static readonly DateOnly WindowStart = new(2043, 6, 1);
    private static readonly DateOnly WindowEnd = new(2045, 6, 1);
    private const int FullCompareLimit = 20_000;

    private const string BothDays =
        "not expressible in hron: cron fires on either the day of month or the day of week";
    private const string IntervalDays =
        "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";

    private static string CronMessage(Action action)
    {
        var e = Assert.Throws<HronException>(action);
        Assert.Equal(ErrorKind.Cron, e.Kind);
        return e.Message;
    }

    private static string FromCronError(string cron) => CronMessage(() => Schedule.FromCron(cron));

    private static string FromCron(string cron) => Schedule.FromCron(cron).ToString();

    /// <summary>
    /// A cron matcher written from the cron rules alone, sharing no code with the library.
    /// It expects valid syntax.
    /// </summary>
    private sealed class NaiveCron
    {
        private enum Dom { Any, Days, Last, LastWeekday, Nearest }

        private enum Dow { Any, Days, Nth, Last }

        private static readonly string[] MonthNames =
            ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
        private static readonly string[] DayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

        private readonly bool[] _minutes;
        private readonly bool[] _hours;
        private readonly bool[] _months;
        private readonly Dom _dom;
        private readonly bool[] _domDays = [];
        private readonly ulong _domNearest;
        private readonly Dow _dow;
        private readonly bool[] _dowDays = [];
        private readonly ulong _dowDay;
        private readonly ulong _dowNth;

        public NaiveCron(string cron)
        {
            cron = cron.Trim().ToLowerInvariant() switch
            {
                "@yearly" or "@annually" => "0 0 1 1 *",
                "@monthly" => "0 0 1 * *",
                "@weekly" => "0 0 * * 0",
                "@daily" or "@midnight" => "0 0 * * *",
                "@hourly" => "0 * * * *",
                var other => other
            };
            var f = cron.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            Assert.True(f.Length == 5, $"naive matcher given {cron}");

            var dom = f[2];
            if (dom is "*" or "?")
            {
                _dom = Dom.Any;
            }
            else if (dom == "l")
            {
                _dom = Dom.Last;
            }
            else if (dom == "lw")
            {
                _dom = Dom.LastWeekday;
            }
            else if (dom.EndsWith('w'))
            {
                _dom = Dom.Nearest;
                _domNearest = NaiveNumber(dom[..^1], []);
            }
            else
            {
                _dom = Dom.Days;
                _domDays = NaiveSet(dom, 1, 31, 31, []);
            }

            var dow = f[4];
            if (dow is "*" or "?")
            {
                _dow = Dow.Any;
            }
            else if (dow.Contains('#'))
            {
                var parts = dow.Split('#', 2);
                _dow = Dow.Nth;
                _dowDay = NaiveNumber(parts[0], DayNames) % 7;
                _dowNth = NaiveNumber(parts[1], []);
            }
            else if (dow.EndsWith('l'))
            {
                _dow = Dow.Last;
                _dowDay = NaiveNumber(dow[..^1], DayNames) % 7;
            }
            else
            {
                var days = NaiveSet(dow, 0, 7, 6, DayNames);
                days[0] |= days[7];
                _dow = Dow.Days;
                _dowDays = days[..7];
            }

            _minutes = NaiveSet(f[0], 0, 59, 59, []);
            _hours = NaiveSet(f[1], 0, 23, 23, []);
            _months = NaiveSet(f[3], 1, 12, 12, MonthNames);
        }

        public List<(int Hour, int Minute)> Times()
        {
            var times = new List<(int, int)>();
            for (var hour = 0; hour < 24; hour++)
            {
                for (var minute = 0; minute < 60; minute++)
                {
                    if (_hours[hour] && _minutes[minute])
                    {
                        times.Add((hour, minute));
                    }
                }
            }
            return times;
        }

        public bool FiresOn(DateOnly d)
        {
            var day = d.Day;
            var last = DateTime.DaysInMonth(d.Year, d.Month);
            var weekday = (ulong)d.DayOfWeek;
            var weekdays = Enumerable.Range(1, last)
                .Where(n => new DateOnly(d.Year, d.Month, n).DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday))
                .ToList();
            bool? dom = _dom switch
            {
                Dom.Any => null,
                Dom.Days => _domDays[day],
                Dom.Last => day == last,
                Dom.LastWeekday => day == weekdays[^1],
                _ => _domNearest <= (ulong)last && day == Nearest(weekdays, (int)_domNearest),
            };
            bool? dow = _dow switch
            {
                Dow.Any => null,
                Dow.Days => _dowDays[weekday],
                Dow.Nth => weekday == _dowDay && (ulong)((day - 1) / 7 + 1) == _dowNth,
                _ => weekday == _dowDay && day + 7 > last,
            };
            var dayMatches = (dom, dow) switch
            {
                (null, null) => true,
                ({ } a, null) => a,
                (null, { } b) => b,
                ({ } a, { } b) => a || b,
            };
            return _months[d.Month] && dayMatches;
        }

        private static int Nearest(List<int> weekdays, int n)
        {
            var best = weekdays[0];
            foreach (var w in weekdays)
            {
                if (Math.Abs(w - n) < Math.Abs(best - n))
                {
                    best = w;
                }
            }
            return best;
        }

        public bool BothDaysRestricted() => _dom != Dom.Any && _dow != Dow.Any;

        public bool DaysCarryAnInterval() => (_dom, _dow) switch
        {
            (Dom.Any, Dow.Any or Dow.Days) => true,
            (Dom.Days, Dow.Any) => _domDays[1..].All(d => d),
            _ => false,
        };

        private static ulong NaiveNumber(string text, string[] names)
        {
            var index = Array.IndexOf(names, text);
            if (index >= 0)
            {
                return (ulong)index;
            }
            return ulong.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : ulong.MaxValue;
        }

        private static bool[] NaiveSet(string field, ulong min, ulong max, ulong starMax, string[] names)
        {
            var set = new bool[max + 1];
            foreach (var item in field.Split(','))
            {
                var slash = item.Split('/', 2);
                var range = slash[0];
                ulong? step = slash.Length == 2 ? NaiveNumber(slash[1], []) : null;
                ulong low;
                ulong high;
                if (range == "*")
                {
                    (low, high) = (min, starMax);
                }
                else if (range.Split('-', 2) is [var a, var b])
                {
                    (low, high) = (NaiveNumber(a, names), NaiveNumber(b, names));
                }
                else
                {
                    low = NaiveNumber(range, names);
                    high = step is null ? low : Math.Max(low, starMax);
                }
                var by = step ?? 1;
                for (var value = low; value <= high;)
                {
                    set[value] = true;
                    if (by > ulong.MaxValue - value)
                    {
                        break;
                    }
                    value += by;
                }
            }
            return set;
        }
    }

    private static IEnumerable<DateOnly> WindowDays()
    {
        for (var d = WindowStart; d < WindowEnd; d = d.AddDays(1))
        {
            yield return d;
        }
    }

    private static DateTimeOffset Utc(DateOnly d, int hour, int minute) =>
        new(d.Year, d.Month, d.Day, hour, minute, 0, TimeSpan.Zero);

    private static DateTimeOffset At(DateOnly d, (int Hour, int Minute) t) => Utc(d, t.Hour, t.Minute);

    private static void AssertFiresAs(Schedule schedule, NaiveCron cron, string label)
    {
        var times = cron.Times();
        var days = WindowDays().Where(cron.FiresOn).ToList();
        if (days.Count * times.Count <= FullCompareLimit)
        {
            AssertEachOccurrence(schedule, days, times, WindowEnd, label);
            return;
        }
        AssertEachOccurrence(schedule, days[..2], times, days[1].AddDays(1), label);
        // Too many to compare one by one. In UTC an hron schedule fires at the same
        // times on every day it fires, so the two days compared in full stand for the
        // times of the rest; on each day the first and the last time, searched from
        // the day before, show that it fires that day and on no day between.
        var cursor = Utc(WindowStart, 0, 0).AddSeconds(-1);
        foreach (var d in days)
        {
            Assert.True(At(d, times[0]) == schedule.NextFrom(cursor), $"{label}: first time on {d:O}");
            var endOfDay = Utc(d.AddDays(1), 0, 0);
            Assert.True(At(d, times[^1]) == schedule.PreviousFrom(endOfDay), $"{label}: last time on {d:O}");
            cursor = endOfDay.AddSeconds(-1);
        }
        var after = schedule.NextFrom(cursor);
        Assert.True(
            after is null || after.Value >= Utc(WindowEnd, 0, 0),
            $"{label}: fires on {after:O}, after the last day the cron fires");
    }

    private static void AssertEachOccurrence(
        Schedule schedule,
        List<DateOnly> days,
        List<(int Hour, int Minute)> times,
        DateOnly end,
        string label)
    {
        var from = Utc(WindowStart, 0, 0).AddSeconds(-1);
        var to = Utc(end, 0, 0).AddSeconds(-1);
        using var expected = days.SelectMany(d => times.Select(t => At(d, t))).GetEnumerator();
        using var actual = schedule.Between(from, to).GetEnumerator();
        while (true)
        {
            DateTimeOffset? e = expected.MoveNext() ? expected.Current : null;
            DateTimeOffset? a = actual.MoveNext() ? actual.Current : null;
            if (e is null && a is null)
            {
                return;
            }
            Assert.True(e == a, $"{label}: expected {e:O}, got {a:O}");
        }
    }

    private static bool HasEqualGaps(List<(int Hour, int Minute)> times)
    {
        var minutes = times.Select(t => t.Hour * 60 + t.Minute).ToList();
        return minutes.Count >= 3
            && minutes.Zip(minutes.Skip(1)).All(w => w.Second - w.First == minutes[1] - minutes[0]);
    }

    /// <summary>
    /// xorshift64*, so the generated cases are the same on every run.
    /// </summary>
    private sealed class Rng(ulong state)
    {
        public string Pick(string[] items) => items[PickIndex(items.Length)];

        public int PickIndex(int length)
        {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            var n = (state * 0x2545_f491_4f6c_dd1dUL) >> 32;
            return (int)(n % (ulong)length);
        }
    }

    private static readonly string[] MinuteFields =
    [
        "0", "30", "*/15", "0-30/10", "5,35", "*", "59", "*/7", "00", "10-50/20", "45/5", "0/20", "1-3",
        "*/99999999999999999999", "0,15,30,45", "5-10/5", "0-59/30", "*/20",
    ];
    private static readonly string[] HourFields =
    [
        "9", "*", "*/2", "9-17", "9-17/2", "0,12", "23", "0-20/4", "*/5", "22,0,2", "1-23", "7/30", "009",
        "0-11", "*/1", "12-12/250", "0-16/4", "1-21/4",
    ];
    private static readonly string[] DomFields =
    [
        "*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29", "30", "lw", "1W", "31W",
        "*/2", "1-31", "5-20/3", "15,1", "02", "l", "28-31", "30W", "29w", "1-30", "2-31",
    ];
    private static readonly string[] MonthFields =
    [
        "*", "1", "JAN", "1-3", "*/3", "2", "dec", "4", "feb", "1,7", "jun-aug", "12,1", "*/12", "2/5",
        "12-12/250", "Sep", "2", "2",
    ];
    private static readonly string[] DowFields =
    [
        "*", "1-5", "MON", "0", "7", "5L", "1#2", "SUN#1", "?", "1-5/2", "sat,sun", "0-7", "7/2", "5-7",
        "fri#5", "1#5", "0l", "mon-fri/2", "6,7", "7,1", "0-6", "5/1", "*/3", "tue-thu", "1,1,3", "1-4",
        "mon-thu", "1-6", "0-5", "0,6,1", "sun,sat",
    ];
    private static readonly string[] AnyDay = ["*"];

    // Two crons in three keep one day field `*`, so most convert; the third draws
    // both, so some are rejected for restricting both.
    private static List<string> GeneratedCrons(ulong shard)
    {
        var rng = new Rng(0x9e37_79b9_7f4a_7c15UL ^ shard);
        return Enumerable.Range(0, 150)
            .Select(i =>
            {
                var (dom, dow) = (i % 3) switch
                {
                    0 => (DomFields, AnyDay),
                    1 => (AnyDay, DowFields),
                    _ => (DomFields, DowFields),
                };
                string[][] fields = [MinuteFields, HourFields, dom, MonthFields, dow];
                return string.Join(" ", fields.Select(rng.Pick).ToList());
            })
            .ToList();
    }

    [Theory]
    [InlineData(0UL)]
    [InlineData(1UL)]
    [InlineData(2UL)]
    [InlineData(3UL)]
    public void FromCronIsExact(ulong shard)
    {
        var accepted = 0;
        foreach (var cron in GeneratedCrons(shard))
        {
            var naive = new NaiveCron(cron);
            var times = naive.Times();
            if (naive.BothDaysRestricted())
            {
                Assert.Equal(BothDays, FromCronError(cron));
                continue;
            }
            var interval = naive.DaysCarryAnInterval() && HasEqualGaps(times);
            if (times.Count > 24 && !interval)
            {
                var expected = HasEqualGaps(times)
                    ? IntervalDays
                    : $"not expressible in hron: {times.Count} times a day are too many to list";
                Assert.Equal(expected, FromCronError(cron));
                continue;
            }
            var schedule = Schedule.FromCron(cron);
            AssertFiresAs(schedule, naive, cron);

            var back = schedule.ToCron();
            var again = Schedule.FromCron(back);
            var label = $"{cron} -> {schedule} -> {back}";
            if (again.ToString() != schedule.ToString())
            {
                AssertFiresAs(again, naive, label);
            }
            var naiveBack = new NaiveCron(back);
            Assert.Equal(times, naiveBack.Times());
            foreach (var d in WindowDays())
            {
                Assert.True(naive.FiresOn(d) == naiveBack.FiresOn(d), $"{label} on {d:O}");
            }
            accepted++;
        }
        Assert.True(accepted >= 60, $"only {accepted} generated crons were accepted");
    }

    private static readonly string[] TimeLists =
    [
        "09:00",
        "00:00",
        "23:59",
        "09:00, 17:00",
        "17:00, 09:00, 09:00",
        "00:00, 12:00",
        "09:00, 13:00, 17:00",
        "09:00, 17:30",
        "00:05, 00:35",
        "00:00, 00:01, 00:02, 00:30",
        "00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10",
        "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59",
        "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00",
        "09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00, 15:30",
        "09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12, 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24",
    ];

    // Each with the month it names, which a `during` must include.
    private static readonly (string Days, string? OwnMonth)[] DayExpressions =
    [
        ("every day", null),
        ("every weekday", null),
        ("every weekend", null),
        ("every monday", null),
        ("every sunday, saturday", null),
        ("every friday, saturday, sunday", null),
        ("every week on tuesday, friday", null),
        ("every 1 day", null),
        ("every month on the 1st", null),
        ("every month on the 1st to 5th, 20th", null),
        ("every month on the 31st", null),
        ("every month on the 15th, 1st", null),
        ("every month on the 1st to 31st", null),
        ("every month on the last day", null),
        ("every month on the last weekday", null),
        ("every month on the nearest weekday to 1st", null),
        ("every month on the nearest weekday to 31st", null),
        ("every month on the nearest weekday to 15th", null),
        ("every month on the first monday", null),
        ("every month on the fifth friday", null),
        ("every month on the last sunday", null),
        ("every year on feb 29", "feb"),
        ("every year on dec 25", "dec"),
        ("every year on the 15th of march", "mar"),
        ("every year on the first monday of mar", "mar"),
        ("every year on the fifth monday of feb", "feb"),
        ("every year on the last friday of feb", "feb"),
        ("every year on the last weekday of dec", "dec"),
        ("on feb 14", "feb"),
        ("on feb 29", "feb"),
    ];
    private static readonly string[] Intervals =
    [
        "every 30 min from 09:00 to 17:30",
        "every 15 min from 00:00 to 23:59",
        "every 2 hours from 00:00 to 23:59",
        "every 7 hours from 00:00 to 23:59",
        "every 45 min from 09:00 to 17:00",
        "every 20 min from 09:00 to 17:40",
        "every 1 minute from 00:00 to 23:59",
        "every 120 min from 01:00 to 23:00",
        "every 2147483647 hours from 00:00 to 23:59",
        "every 5 min from 10:00 to 10:30",
        "every 4 hours from 00:00 to 20:00",
        "every 1 hour from 09:05 to 17:05",
        "every 30 min from 09:00 to 17:00",
    ];
    private static readonly string[] IntervalDayFilters = ["", " on weekday", " on weekend", " on monday, friday"];
    private static readonly string[] During =
    [
        "",
        "",
        " during feb",
        " during dec",
        " during jan, jul",
        " during dec, jan, feb",
        " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
    ];

    private sealed record GeneratedSchedule(string Hron, List<ulong> Times, string? OwnMonth, string During);

    private static List<GeneratedSchedule> GeneratedSchedules()
    {
        var rng = new Rng(0x2545_f491_4f6c_dd1dUL);
        return Enumerable.Range(0, 240)
            .Select(i =>
            {
                var during = rng.Pick(During);
                if (i % 3 == 0)
                {
                    var filter = rng.Pick(IntervalDayFilters);
                    var interval = rng.Pick(Intervals);
                    return new GeneratedSchedule($"{interval}{filter}{during}", NaiveIntervalTimes(interval), null, during);
                }
                var (days, ownMonth) = DayExpressions[rng.PickIndex(DayExpressions.Length)];
                var times = rng.Pick(TimeLists);
                return new GeneratedSchedule(
                    $"{days} at {times}{during}",
                    times.Split(", ").Select(NaiveMinuteOfDay).ToList(),
                    ownMonth,
                    during);
            })
            .ToList();
    }

    private static ulong NaiveMinuteOfDay(string time)
    {
        var parts = time.Split(':');
        return ulong.Parse(parts[0], CultureInfo.InvariantCulture) * 60 + ulong.Parse(parts[1], CultureInfo.InvariantCulture);
    }

    private static List<ulong> NaiveIntervalTimes(string interval)
    {
        var words = interval.Split(' ');
        var every = ulong.Parse(words[1], CultureInfo.InvariantCulture);
        var step = words[2].StartsWith("hour") ? every * 60 : every;
        var (from, to) = (NaiveMinuteOfDay(words[4]), NaiveMinuteOfDay(words[6]));
        var times = new List<ulong>();
        for (var t = from; t <= to; t++)
        {
            if ((t - from) % step == 0)
            {
                times.Add(t);
            }
        }
        return times;
    }

    /// <summary>
    /// The reason ToCron must give, decided from the generated parts alone.
    /// </summary>
    private static string? ExpectedToCronFailure(GeneratedSchedule generated)
    {
        if (generated.OwnMonth is { } month && generated.During != "" && !generated.During.Contains(month))
        {
            return "during excludes the schedule's month";
        }
        var times = generated.Times.Distinct().ToList();
        var minutes = times.Select(t => t % 60).Distinct().Count();
        var hours = times.Select(t => t / 60).Distinct().Count();
        return minutes * hours != times.Count
            ? "times are not every combination of their minutes and hours"
            : null;
    }

    [Fact]
    public void ToCronIsExact()
    {
        var accepted = 0;
        var rejected = 0;
        foreach (var generated in GeneratedSchedules())
        {
            var hron = generated.Hron;
            var schedule = Schedule.Parse(hron);
            if (ExpectedToCronFailure(generated) is { } reason)
            {
                Assert.Equal($"not expressible as cron: {reason}", CronMessage(() => schedule.ToCron()));
                rejected++;
                continue;
            }
            var cron = schedule.ToCron();
            var naive = new NaiveCron(cron);
            AssertFiresAs(schedule, naive, $"{hron} -> {cron}");
            accepted++;

            var times = naive.Times();
            var label = $"{hron} -> {cron} -> FromCron";
            var interval = naive.DaysCarryAnInterval() && HasEqualGaps(times);
            if (times.Count > 24 && !interval)
            {
                var expected = HasEqualGaps(times)
                    ? IntervalDays
                    : $"not expressible in hron: {times.Count} times a day are too many to list";
                Assert.Equal(expected, FromCronError(cron));
                continue;
            }
            AssertFiresAs(Schedule.FromCron(cron), naive, label);
        }
        Assert.True(
            accepted >= 60 && rejected >= 20,
            $"only {accepted} generated schedules converted and {rejected} were rejected");
    }

    [Fact]
    public void ValuesOfAnyLengthNeverOverflow()
    {
        var longZeros = new string('0', 10_000);
        Assert.Equal("every day at 09:09", FromCron($"{longZeros}9 {longZeros}9 * * *"));
        var huge = new string('9', 10_000);
        Assert.Equal($"day of week ordinal must be 1-5, got {huge}", FromCronError($"0 9 * * 1#{huge}"));
        Assert.Equal($"day of month must be 1-31, got {huge}", FromCronError($"0 9 {huge}W * *"));
        Assert.Equal($"hour must be 0-23, got {huge}", FromCronError($"0 {huge}-1 * * *"));
        Assert.Equal("every monday at 09:00", FromCron($"0 9 * * 1-5/{huge}"));
        Assert.Equal("day of week step must be at least 1", FromCronError($"0 9 * * */{longZeros}"));
        Assert.Equal("every sunday at 09:00", FromCron($"0 9 * * 0-7/{longZeros}7"));
    }

    [Fact]
    public void ALongFieldIsParsedInLinearTime()
    {
        var items = string.Join(",", Enumerable.Repeat("1", 200_000));
        Assert.Equal("every month on the 1st at 09:00", FromCron($"0 9 {items} * *"));
        var ranges = string.Join(",", Enumerable.Repeat("0-59/1", 50_000));
        Assert.Equal("every 1 minute from 09:00 to 09:59", FromCron($"{ranges} 9 * * *"));
    }

    [Fact]
    public void SevenMinuteStepsConvertOnlyWithinAnHour()
    {
        Assert.Equal("every 7 min from 09:00 to 09:56", FromCron("*/7 9 * * *"));
        Assert.Equal(
            "not expressible in hron: 216 times a day are too many to list",
            FromCronError("*/7 * * * *"));
    }

    [Fact]
    public void NaiveMatcherAgreesWithKnownDates()
    {
        static bool Fires(string cron, int year, int month, int day) =>
            new NaiveCron(cron).FiresOn(new DateOnly(year, month, day));

        Assert.True(Fires("0 9 * 2 1#5", 2044, 2, 29));
        Assert.True(Fires("0 9 1W * *", 2043, 8, 3), "Saturday the 1st moves to Monday");
        Assert.True(Fires("0 9 31W * *", 2043, 8, 31), "Monday the 31st");
        Assert.True(Fires("0 9 30W * *", 2044, 4, 29), "Saturday the 30th moves to Friday");
        Assert.True(Fires("0 9 31W * *", 2044, 7, 29), "Sunday the 31st moves to Friday");
        Assert.False(Fires("0 9 31W * *", 2044, 4, 30), "April has no 31st");
        Assert.True(Fires("0 9 LW * *", 2044, 4, 29));
        Assert.True(Fires("0 9 * * 5L", 2044, 4, 29));
        Assert.False(Fires("0 9 * * 5L", 2044, 4, 22));
    }
}
