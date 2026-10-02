using Hron.Ast;
using Hron.Cron;
using Hron.Eval;
using HronParser = Hron.Parser.Parser;
using HronDisplay = Hron.Display.Display;

namespace Hron;

/// <summary>
/// Only the instant of a <see cref="DateTimeOffset"/> argument matters. Every result has the offset
/// of the schedule's timezone at that instant, or zero when it has none. A schedule never changes,
/// and two schedules are equal when their parts are.
/// </summary>
public sealed class Schedule : IEquatable<Schedule>
{
    private readonly ScheduleData _data;
    private readonly TimeZoneInfo _zoneInfo;

    private Schedule(ScheduleData data, TimeZoneInfo zoneInfo)
    {
        _data = data;
        _zoneInfo = zoneInfo;
    }

    /// <summary>
    /// Parses an hron expression into a Schedule.
    /// </summary>
    /// <exception cref="ArgumentNullException">If input is null</exception>
    /// <exception cref="HronException">A lex or parse error when the input is not a valid expression</exception>
    public static Schedule Parse(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var data = HronParser.Parse(input);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Converts a 5-field cron expression to a Schedule that fires at the same times.
    /// </summary>
    /// <exception cref="ArgumentNullException">If cronExpr is null</exception>
    /// <exception cref="HronException">A cron error when the input is not valid cron or has no exact hron equivalent</exception>
    public static Schedule FromCron(string cronExpr)
    {
        ArgumentNullException.ThrowIfNull(cronExpr);
        var data = CronConverter.FromCron(cronExpr);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Checks an hron expression without throwing a <see cref="HronException"/>.
    /// </summary>
    /// <returns>True when <see cref="Parse"/> would accept the input, false when it would throw a <see cref="HronException"/></returns>
    /// <exception cref="ArgumentNullException">If input is null</exception>
    public static bool Validate(string input)
    {
        ArgumentNullException.ThrowIfNull(input);
        try
        {
            HronParser.Parse(input);
            return true;
        }
        catch (HronException)
        {
            return false;
        }
    }

    /// <summary>
    /// Computes the next occurrence strictly after the given time.
    /// </summary>
    /// <returns>The next occurrence, or null if none exists or now is outside the supported range</returns>
    public DateTimeOffset? NextFrom(DateTimeOffset now)
    {
        return Evaluator.NextFrom(_data, now, _zoneInfo);
    }

    /// <summary>
    /// Computes up to n occurrences strictly after the given time.
    /// </summary>
    /// <returns>At most n occurrences in order, empty when n &lt;= 0 or now is outside the supported range</returns>
    public IReadOnlyList<DateTimeOffset> NextNFrom(DateTimeOffset now, int n)
    {
        return Evaluator.NextNFrom(_data, now, n, _zoneInfo);
    }

    /// <summary>
    /// Computes the most recent occurrence strictly before the given time.
    /// </summary>
    /// <returns>The previous occurrence, or null if none exists or now is outside the supported range</returns>
    public DateTimeOffset? PreviousFrom(DateTimeOffset now)
    {
        return Evaluator.PreviousFrom(_data, now, _zoneInfo);
    }

    /// <summary>
    /// Checks if the minute containing a datetime is an occurrence of this schedule.
    /// </summary>
    /// <returns>True if the start of that minute is an occurrence; false outside the supported range</returns>
    public bool Matches(DateTimeOffset dateTime)
    {
        return Evaluator.Matches(_data, dateTime, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences strictly after the given time.
    /// </summary>
    /// <returns>An enumerable of occurrences, empty when from is outside the supported range</returns>
    public IEnumerable<DateTimeOffset> Occurrences(DateTimeOffset from)
    {
        return Evaluator.Occurrences(_data, from, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences where from &lt; occurrence &lt;= to.
    /// </summary>
    /// <returns>An enumerable of occurrences in the range, empty when either bound is outside the supported range</returns>
    public IEnumerable<DateTimeOffset> Between(DateTimeOffset from, DateTimeOffset to)
    {
        return Evaluator.Between(_data, from, to, _zoneInfo);
    }

    /// <summary>
    /// Converts this schedule to a 5-field cron expression that fires at the same times.
    /// The schedule's timezone is not part of the cron.
    /// </summary>
    /// <exception cref="HronException">A cron error when cron cannot fire at exactly the same times</exception>
    public string ToCron() => CronConverter.ToCron(_data);

    /// <summary>
    /// The IANA timezone name in its canonical capitalization, or null if not specified.
    /// </summary>
    public string? Timezone => string.IsNullOrEmpty(_data.Timezone) ? null : _data.Timezone;

    /// <summary>
    /// The repeat: a <see cref="DayRepeat"/>, <see cref="IntervalRepeat"/>, <see cref="WeekRepeat"/>,
    /// <see cref="MonthRepeat"/>, <see cref="YearRepeat"/> or <see cref="SingleDate"/>.
    /// </summary>
    public IScheduleExpr Expression => _data.Expression;

    /// <summary>
    /// The except dates in the order written, empty without an except clause.
    /// </summary>
    public IReadOnlyList<ExceptionSpec> Except => _data.Except;

    /// <summary>
    /// The until date, or null if not specified.
    /// </summary>
    public UntilSpec? Until => _data.Until;

    /// <summary>
    /// The starting date as <c>YYYY-MM-DD</c>, or null if not specified.
    /// </summary>
    public string? Starting => _data.Starting;

    /// <summary>
    /// The during months in the order written, empty without a during clause.
    /// </summary>
    public IReadOnlyList<MonthName> During => _data.During;

    /// <summary>
    /// Returns the canonical string representation of this schedule, which parses back to an equal schedule.
    /// </summary>
    public override string ToString() => HronDisplay.Render(_data);

    /// <summary>
    /// True when other is a schedule with equal parts: every getter equal, lists in the same order with
    /// the same duplicates. False for null.
    /// </summary>
    public bool Equals(Schedule? other) => other is not null && _data.Equals(other._data);

    /// <summary>
    /// True when obj is a <see cref="Schedule"/> with equal parts; false for null or any other type.
    /// </summary>
    public override bool Equals(object? obj) => obj is Schedule other && Equals(other);

    /// <summary>
    /// Equal schedules have equal hash codes.
    /// </summary>
    public override int GetHashCode() => _data.GetHashCode();

    /// <summary>
    /// True when both are null, or both are schedules with equal parts.
    /// </summary>
    public static bool operator ==(Schedule? left, Schedule? right) => left is null ? right is null : left.Equals(right);

    public static bool operator !=(Schedule? left, Schedule? right) => !(left == right);

    /// <summary>
    /// UTC when unset, so results never depend on the host zone.
    /// </summary>
    private static TimeZoneInfo ResolveTimezone(string? tzName)
    {
        return string.IsNullOrEmpty(tzName) ? TimeZoneInfo.Utc : TimeZoneInfo.FindSystemTimeZoneById(tzName);
    }
}
