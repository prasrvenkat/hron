using System.Collections;
using System.Text.Json;
using Hron.Ast;
using Xunit;

namespace Hron.Tests;

public class PartsTest
{
    private static readonly JsonElement Spec =
        JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "tests.json"))).RootElement;

    public static TheoryData<string> ParseInputs()
    {
        var data = new TheoryData<string>();
        foreach (var section in Spec.GetProperty("parse").EnumerateObject())
        {
            if (section.Value.ValueKind != JsonValueKind.Object) continue;
            foreach (var tc in section.Value.GetProperty("tests").EnumerateArray())
            {
                data.Add(tc.GetProperty("input").GetString()!);
            }
        }
        return data;
    }

    public static TheoryData<string> FromCronInputs()
    {
        var data = new TheoryData<string>();
        foreach (var tc in Spec.GetProperty("cron").GetProperty("from_cron").GetProperty("tests").EnumerateArray())
        {
            data.Add(tc.GetProperty("cron").GetString()!);
        }
        return data;
    }

    [Fact]
    public void TheGettersReturnEachClause()
    {
        var s = Schedule.Parse(
            "every weekday at 09:00 except dec 25, 2026-07-04 until 2026-12-31 starting 2026-01-05 during jan, feb in america/new_york");

        Assert.Equal(new DayRepeat(1, new DayFilter(DayFilterKind.Weekday, []), [new TimeOfDay(9, 0)]), s.Expression);
        Assert.Equal(
            new[] { new ExceptionSpec(ExceptionSpecKind.Named, MonthName.December, 25, null), new ExceptionSpec(ExceptionSpecKind.Iso, null, 0, "2026-07-04") },
            s.Except);
        Assert.Equal(new UntilSpec(UntilSpecKind.Iso, "2026-12-31", null, 0), s.Until);
        Assert.Equal("2026-01-05", s.Starting);
        Assert.Equal(new[] { MonthName.January, MonthName.February }, s.During);
        Assert.Equal("America/New_York", s.Timezone);
    }

    [Fact]
    public void WithoutClausesTheListsAreEmptyAndTheRestNull()
    {
        var s = Schedule.Parse("every day at 09:00");

        Assert.Empty(s.Except);
        Assert.Null(s.Until);
        Assert.Null(s.Starting);
        Assert.Empty(s.During);
        Assert.Null(s.Timezone);
    }

    [Theory]
    [InlineData("every 30 min from 09:00 to 17:00", typeof(IntervalRepeat))]
    [InlineData("every monday at 09:00", typeof(DayRepeat))]
    [InlineData("every 2 weeks on monday at 09:00", typeof(WeekRepeat))]
    [InlineData("every month on the 1st at 09:00", typeof(MonthRepeat))]
    [InlineData("every year on dec 25 at 00:00", typeof(YearRepeat))]
    [InlineData("on feb 14 at 09:00", typeof(SingleDate))]
    public void TheExpressionIsTheRepeatOfItsKind(string input, Type kind)
    {
        Assert.IsType(kind, Schedule.Parse(input).Expression);
    }

    [Fact]
    public void APartPrintsItsListsItemByItem()
    {
        var s = Schedule.Parse("every weekday at 09:00, 17:00");

        Assert.Equal(
            "DayRepeat { Interval = 1, Days = DayFilter { Kind = Weekday, Days = [] }, Times = [09:00, 17:00] }",
            s.Expression.ToString());
    }

    [Fact]
    public void ANamedUntilKeepsItsMonthAndDay()
    {
        var s = Schedule.Parse("every day at 09:00 until dec 31 starting 2026-01-01");

        Assert.Equal(new UntilSpec(UntilSpecKind.Named, null, MonthName.December, 31), s.Until);
    }

    [Fact]
    public void AListCastBackToAListIsNull()
    {
        var s = Schedule.Parse("every 2 weeks on monday, friday at 09:00, 17:00 except dec 25 during jan");
        var week = Assert.IsType<WeekRepeat>(s.Expression);

        Assert.Null(s.Except as List<ExceptionSpec>);
        Assert.Null(s.During as List<MonthName>);
        Assert.Null(week.WeekDays as List<Weekday>);
        Assert.Null(week.Times as List<TimeOfDay>);
    }

    [Theory]
    [MemberData(nameof(ParseInputs))]
    public void NoListInAnyPartIsAMutableCollection(string input)
    {
        var s = Schedule.Parse(input);
        var mutable = new List<string>();

        foreach (var getter in typeof(Schedule).GetProperties())
        {
            CollectMutableLists(getter.GetValue(s), getter.Name, mutable);
        }

        Assert.Empty(mutable);
    }

    private static void CollectMutableLists(object? value, string path, List<string> mutable)
    {
        if (value is null or string || value.GetType().IsEnum || value.GetType().IsPrimitive)
        {
            return;
        }
        if (value is IEnumerable items)
        {
            var collectionTypes = value.GetType().GetInterfaces()
                .Where(i => i == typeof(IList) || (i.IsGenericType && i.GetGenericTypeDefinition() == typeof(ICollection<>)));
            if (collectionTypes.Any())
            {
                mutable.Add($"{path}: {value.GetType()}");
            }
            var index = 0;
            foreach (var item in items)
            {
                CollectMutableLists(item, $"{path}[{index++}]", mutable);
            }
            return;
        }
        if (value.GetType().Namespace == "Hron.Ast")
        {
            foreach (var property in value.GetType().GetProperties())
            {
                CollectMutableLists(property.GetValue(value), $"{path}.{property.Name}", mutable);
            }
        }
    }

    [Fact]
    public void APartPropertyHasNoSetterThatReflectionCanCall()
    {
        var s = Schedule.Parse("every 2 days at 09:00");
        var interval = typeof(DayRepeat).GetProperty(nameof(DayRepeat.Interval))!;

        Assert.Throws<ArgumentException>(() => interval.SetValue(s.Expression, 5));
        Assert.Equal("every 2 days at 09:00", s.ToString());
        Assert.Equal(Schedule.Parse("every 2 days at 09:00").GetHashCode(), s.GetHashCode());
    }

    [Fact]
    public void APartBuiltFromAnArrayKeepsItsOwnCopy()
    {
        var before = new Dictionary<Type, object?>
        {
            [typeof(Weekday)] = Weekday.Monday,
            [typeof(TimeOfDay)] = new TimeOfDay(9, 0),
            [typeof(DayOfMonthSpec)] = new DayOfMonthSpec(DayOfMonthSpecKind.Single, 1, 0, 0),
        };
        var after = new Dictionary<Type, object?>
        {
            [typeof(Weekday)] = Weekday.Tuesday,
            [typeof(TimeOfDay)] = new TimeOfDay(10, 0),
            [typeof(DayOfMonthSpec)] = new DayOfMonthSpec(DayOfMonthSpecKind.Single, 2, 0, 0),
        };
        var seen = new List<string>();

        foreach (var type in typeof(Schedule).Assembly.GetExportedTypes().Where(t => t.Namespace == "Hron.Ast"))
        {
            var constructor = type.GetConstructors().SingleOrDefault(c => c.GetParameters().Any(p => IsList(p.ParameterType)));
            if (constructor is null)
            {
                continue;
            }
            var parameters = constructor.GetParameters();
            var args = parameters
                .Select(p => IsList(p.ParameterType)
                    ? MakeArray(p.ParameterType.GetGenericArguments()[0], before)
                    : p.ParameterType.IsValueType ? Activator.CreateInstance(p.ParameterType) : null)
                .ToArray();
            var part = constructor.Invoke(args);

            foreach (var array in args.OfType<Array>())
            {
                array.SetValue(after[array.GetType().GetElementType()!], 0);
            }
            foreach (var parameter in parameters.Where(p => IsList(p.ParameterType)))
            {
                var name = $"{type.Name}.{parameter.Name}";
                seen.Add(name);
                var held = (IEnumerable)type.GetProperty(parameter.Name!)!.GetValue(part)!;
                Assert.True(
                    Equals(before[parameter.ParameterType.GetGenericArguments()[0]], held.Cast<object?>().Single()),
                    $"{name} changed with the array it was given");
            }
        }

        Assert.Equal(
            [
                "DayFilter.Days", "DayRepeat.Times", "MonthRepeat.Times", "MonthTarget.Specs", "SingleDate.Times",
                "WeekRepeat.Times", "WeekRepeat.WeekDays", "YearRepeat.Times",
            ],
            seen.Order(StringComparer.Ordinal));
    }

    private static bool IsList(Type type) =>
        type.IsGenericType && type.GetGenericTypeDefinition() == typeof(IReadOnlyList<>);

    private static Array MakeArray(Type element, Dictionary<Type, object?> values)
    {
        var array = Array.CreateInstance(element, 1);
        array.SetValue(values[element], 0);
        return array;
    }

    [Fact]
    public void NineAndNineOClockAreEqual()
    {
        var a = Schedule.Parse("every day at 9:00");
        var b = Schedule.Parse("every day at 09:00");

        Assert.True(a.Equals(b));
        Assert.True(a.Equals((object)b));
        Assert.True(a == b);
        Assert.False(a != b);
        Assert.Equal(a.GetHashCode(), b.GetHashCode());
        Assert.Single(new HashSet<Schedule> { a, b });
    }

    [Theory]
    [MemberData(nameof(ParseInputs))]
    public void AScheduleEqualsTheParseOfItsToString(string input)
    {
        var s = Schedule.Parse(input);
        var reparsed = Schedule.Parse(s.ToString());

        Assert.NotSame(s, reparsed);
        Assert.True(s == reparsed);
        Assert.Equal(s.GetHashCode(), reparsed.GetHashCode());
    }

    [Theory]
    [MemberData(nameof(FromCronInputs))]
    public void AFromCronScheduleEqualsTheParseOfItsToString(string cron)
    {
        var s = Schedule.FromCron(cron);
        var reparsed = Schedule.Parse(s.ToString());

        Assert.True(s == reparsed);
        Assert.Equal(s.GetHashCode(), reparsed.GetHashCode());
    }

    [Theory]
    [InlineData("every day at 09:00", "every day at 10:00")]
    [InlineData("every day at 09:00", "every day at 09:00 in UTC")]
    [InlineData("every day at 09:00, 17:00", "every day at 17:00, 09:00")]
    [InlineData("every day at 09:00", "every day at 09:00, 09:00")]
    [InlineData("every monday, friday at 09:00", "every friday, monday at 09:00")]
    [InlineData("every weekday at 09:00", "every monday, tuesday, wednesday, thursday, friday at 09:00")]
    [InlineData("every month on the 1st, 15th at 09:00", "every month on the 15th, 1st at 09:00")]
    [InlineData("every day at 09:00 except dec 25, jan 1", "every day at 09:00 except jan 1, dec 25")]
    [InlineData("every day at 09:00 except dec 25", "every day at 09:00 except dec 25, dec 25")]
    [InlineData("every day at 09:00 until 2026-12-31", "every day at 09:00 until 2027-12-31")]
    [InlineData("every day at 09:00 starting 2026-01-01", "every day at 09:00 starting 2026-01-02")]
    [InlineData("every day at 09:00 during jan, feb", "every day at 09:00 during feb, jan")]
    [InlineData("every 2 days at 09:00", "every 3 days at 09:00")]
    public void SchedulesWithDifferentPartsAreNotEqual(string first, string second)
    {
        var a = Schedule.Parse(first);
        var b = Schedule.Parse(second);

        Assert.False(a.Equals(b));
        Assert.False(a == b);
        Assert.True(a != b);
    }

    [Fact]
    public void AScheduleNeverEqualsNullOrAnotherType()
    {
        var s = Schedule.Parse("every day at 09:00");
        Schedule? none = null;

        Assert.False(s.Equals(none));
        Assert.False(s.Equals((object?)null));
        Assert.False(s.Equals("every day at 09:00"));
        Assert.False(s.Equals(s.Expression));
        Assert.False(s == none);
        Assert.False(none == s);
        Assert.True(s != none);
        Assert.True(none == null);
    }
}
