using System.Reflection;
using Hron.Ast;
using Xunit;

namespace Hron.Tests;

/// <summary>
/// C# builds a schedule only through Parse and FromCron, and no public function takes a schedule's
/// parts to build, evaluate, display or convert one (spec/README.md, "Schedules built in code").
/// </summary>
public class PublicApiTest
{
    private static readonly string[] Parts =
    [
        "Hron.Ast.DateSpec", "Hron.Ast.DateSpecKind", "Hron.Ast.DayFilter", "Hron.Ast.DayFilterKind",
        "Hron.Ast.DayOfMonthSpec", "Hron.Ast.DayOfMonthSpecKind", "Hron.Ast.DayRepeat", "Hron.Ast.ExceptionSpec",
        "Hron.Ast.ExceptionSpecKind", "Hron.Ast.IScheduleExpr", "Hron.Ast.IntervalRepeat", "Hron.Ast.IntervalUnit",
        "Hron.Ast.MonthName", "Hron.Ast.MonthRepeat", "Hron.Ast.MonthTarget", "Hron.Ast.MonthTargetKind",
        "Hron.Ast.NearestDirection", "Hron.Ast.OrdinalPosition", "Hron.Ast.SingleDate", "Hron.Ast.TimeOfDay",
        "Hron.Ast.UntilSpec", "Hron.Ast.UntilSpecKind", "Hron.Ast.WeekRepeat", "Hron.Ast.Weekday",
        "Hron.Ast.YearRepeat", "Hron.Ast.YearTarget", "Hron.Ast.YearTargetKind",
    ];

    private static readonly HashSet<string> RecordMembers =
        ["Equals", "GetHashCode", "ToString", "Deconstruct", "op_Equality", "op_Inequality", "<Clone>$"];

    private static readonly Type[] Exported = typeof(Schedule).Assembly.GetExportedTypes();

    private static bool IsPart(Type type) => type.Namespace == "Hron.Ast";

    private static bool MentionsAPart(Type type)
    {
        var element = type.HasElementType ? type.GetElementType()! : type;
        return IsPart(element) || element.GetGenericArguments().Any(MentionsAPart);
    }

    private static IEnumerable<MethodBase> PublicMembers(Type type) =>
        type.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly)
            .Cast<MethodBase>()
            .Concat(type.GetConstructors());

    [Fact]
    public void OnlyTheScheduleItsErrorTypesAndItsPartsAreExported()
    {
        var exported = Exported.Select(t => t.FullName).Order(StringComparer.Ordinal);

        Assert.Equal(
            [.. Parts, "Hron.ErrorKind", "Hron.ErrorKindExtensions", "Hron.HronException", "Hron.Schedule", "Hron.Span"],
            exported);
    }

    [Fact]
    public void OnlyParseAndFromCronMakeASchedule()
    {
        var makers = Exported
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static))
            .Where(m => m.ReturnType == typeof(Schedule))
            .Select(m => $"{m.DeclaringType!.Name}.{m.Name}")
            .Order();

        Assert.Equal(["Schedule.FromCron", "Schedule.Parse"], makers);
        Assert.Empty(typeof(Schedule).GetConstructors());
    }

    [Fact]
    public void NoPublicMemberOutsideThePartsTakesAPart()
    {
        var takers = Exported
            .Where(t => !IsPart(t))
            .SelectMany(PublicMembers)
            .Where(m => m.GetParameters().Any(p => MentionsAPart(p.ParameterType)))
            .Select(m => $"{m.DeclaringType!.Name}.{m.Name}");

        Assert.Empty(takers);
    }

    [Fact]
    public void ThePartsHaveNoMethodsButTheRecordOnes()
    {
        var methods = Exported
            .Where(IsPart)
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly))
            .Where(m => !m.IsSpecialName || m.Name.StartsWith("op_"))
            .Where(m => !RecordMembers.Contains(m.Name))
            .Select(m => $"{m.DeclaringType!.Name}.{m.Name}");

        Assert.Empty(methods);
    }

    [Fact]
    public void TheGettersAreTheSixPartsAndReadOnly()
    {
        var getters = typeof(Schedule).GetProperties(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static);

        Assert.Equal(
            [
                (nameof(Schedule.During), typeof(IReadOnlyList<MonthName>)),
                (nameof(Schedule.Except), typeof(IReadOnlyList<ExceptionSpec>)),
                (nameof(Schedule.Expression), typeof(IScheduleExpr)),
                (nameof(Schedule.Starting), typeof(string)),
                (nameof(Schedule.Timezone), typeof(string)),
                (nameof(Schedule.Until), typeof(UntilSpec)),
            ],
            getters.OrderBy(g => g.Name, StringComparer.Ordinal).Select(g => (g.Name, g.PropertyType)));
        Assert.All(getters, g => Assert.Null(g.SetMethod));
    }

    [Fact]
    public void NoPartHasAPublicOrProtectedSetter()
    {
        var setters = Exported
            .Where(IsPart)
            .SelectMany(t => t.GetProperties(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static))
            .Where(p => p.SetMethod is { } set && (set.IsPublic || set.IsFamily || set.IsFamilyOrAssembly))
            .Select(p => $"{p.DeclaringType!.Name}.{p.Name}");

        Assert.Empty(setters);
    }

    [Fact]
    public void ParseOfNullIsAnArgumentNullException()
    {
        var e = Assert.Throws<ArgumentNullException>(() => Schedule.Parse(null!));
        Assert.Equal("input", e.ParamName);
    }

    [Fact]
    public void ValidateOfNullIsAnArgumentNullException()
    {
        var e = Assert.Throws<ArgumentNullException>(() => Schedule.Validate(null!));
        Assert.Equal("input", e.ParamName);
    }

    [Fact]
    public void FromCronOfNullIsAnArgumentNullException()
    {
        var e = Assert.Throws<ArgumentNullException>(() => Schedule.FromCron(null!));
        Assert.Equal("cronExpr", e.ParamName);
    }

    [Fact]
    public void LexOfANullMessageOrInputIsAnArgumentNullException()
    {
        var span = new Span(0, 1);

        Assert.Equal("message", Assert.Throws<ArgumentNullException>(() => HronException.Lex(null!, span, "x")).ParamName);
        Assert.Equal("input", Assert.Throws<ArgumentNullException>(() => HronException.Lex("m", span, null!)).ParamName);
    }

    [Fact]
    public void ParseOfANullMessageOrInputIsAnArgumentNullException()
    {
        var span = new Span(0, 1);

        Assert.Equal("message", Assert.Throws<ArgumentNullException>(() => HronException.Parse(null!, span, "x")).ParamName);
        Assert.Equal("input", Assert.Throws<ArgumentNullException>(() => HronException.Parse("m", span, null!)).ParamName);
    }

    [Fact]
    public void ParseTakesANullSuggestion()
    {
        Assert.Null(HronException.Parse("m", new Span(0, 1), "x", null).Suggestion);
    }

    [Fact]
    public void EvalOfANullMessageIsAnArgumentNullException()
    {
        Assert.Equal("message", Assert.Throws<ArgumentNullException>(() => HronException.Eval(null!)).ParamName);
    }

    [Fact]
    public void CronOfANullMessageIsAnArgumentNullException()
    {
        Assert.Equal("message", Assert.Throws<ArgumentNullException>(() => HronException.Cron(null!)).ParamName);
    }
}
