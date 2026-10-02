using System.Reflection;
using Xunit;

namespace Hron.Tests;

/// <summary>
/// C# builds a schedule only through Parse and FromCron (spec/README.md, "Schedules built in code").
/// </summary>
public class PublicApiTest
{
    [Fact]
    public void OnlyTheScheduleAndItsErrorTypesAreExported()
    {
        var exported = typeof(Schedule).Assembly.GetExportedTypes().Select(t => t.FullName).Order();

        Assert.Equal(
            ["Hron.ErrorKind", "Hron.ErrorKindExtensions", "Hron.HronException", "Hron.Schedule", "Hron.Span"],
            exported);
    }

    [Fact]
    public void OnlyParseAndFromCronMakeASchedule()
    {
        var makers = typeof(Schedule).Assembly.GetExportedTypes()
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static))
            .Where(m => m.ReturnType == typeof(Schedule))
            .Select(m => $"{m.DeclaringType!.Name}.{m.Name}")
            .Order();

        Assert.Equal(["Schedule.FromCron", "Schedule.Parse"], makers);
        Assert.Empty(typeof(Schedule).GetConstructors());
    }

    [Fact]
    public void TheTimezoneIsTheOnlyGetter()
    {
        var getters = typeof(Schedule).GetProperties(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static);

        var getter = Assert.Single(getters);
        Assert.Equal(nameof(Schedule.Timezone), getter.Name);
        Assert.Equal(typeof(string), getter.PropertyType);
    }

    [Fact]
    public void FromCronOfNullIsAnArgumentNullException()
    {
        var e = Assert.Throws<ArgumentNullException>(() => Schedule.FromCron(null!));
        Assert.Equal("cronExpr", e.ParamName);
    }
}
