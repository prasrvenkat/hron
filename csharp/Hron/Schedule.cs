using Hron.Ast;
using Hron.Cron;
using Hron.Eval;
using HronParser = Hron.Parser.Parser;
using HronDisplay = Hron.Display.Display;

namespace Hron;

/// <summary>
/// The main entry point for parsing and evaluating hron schedule expressions.
/// </summary>
/// <example>
/// <code>
/// var schedule = Schedule.Parse("every weekday at 9:00 except dec 25 in America/New_York");
/// var next = schedule.NextFrom(DateTimeOffset.Now);
/// if (next.HasValue)
/// {
///     Console.WriteLine($"Next occurrence: {next.Value}");
/// }
/// </code>
/// </example>
public sealed class Schedule
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
    /// <param name="input">The hron expression</param>
    /// <returns>The parsed schedule</returns>
    /// <exception cref="HronException">If the input is invalid</exception>
    public static Schedule Parse(string input)
    {
        var data = HronParser.Parse(input);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Converts a 5-field cron expression to a Schedule.
    /// </summary>
    /// <param name="cronExpr">The cron expression</param>
    /// <returns>The parsed schedule</returns>
    /// <exception cref="HronException">If the cron expression is invalid</exception>
    public static Schedule FromCron(string cronExpr)
    {
        var data = CronConverter.FromCron(cronExpr);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Validates an hron expression without throwing.
    /// </summary>
    /// <param name="input">The hron expression</param>
    /// <returns>True if the expression is valid</returns>
    public static bool Validate(string input)
    {
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
    /// Computes the next occurrence after the given time.
    /// </summary>
    /// <param name="now">The reference time</param>
    /// <returns>The next occurrence, or null if none exists</returns>
    public DateTimeOffset? NextFrom(DateTimeOffset now)
    {
        // Convert now to the schedule's timezone
        var nowInTz = TimeZoneInfo.ConvertTime(now, _zoneInfo);
        return Evaluator.NextFrom(_data, nowInTz, _zoneInfo);
    }

    /// <summary>
    /// Computes the next n occurrences after the given time.
    /// </summary>
    /// <param name="now">The reference time</param>
    /// <param name="count">The number of occurrences to compute</param>
    /// <returns>A list of the next n occurrences</returns>
    public IReadOnlyList<DateTimeOffset> NextNFrom(DateTimeOffset now, int count)
    {
        var nowInTz = TimeZoneInfo.ConvertTime(now, _zoneInfo);
        return Evaluator.NextNFrom(_data, nowInTz, count, _zoneInfo);
    }

    /// <summary>
    /// Computes the most recent occurrence strictly before the given time.
    /// </summary>
    /// <param name="now">The reference time (exclusive upper bound)</param>
    /// <returns>The previous occurrence, or null if none exists</returns>
    public DateTimeOffset? PreviousFrom(DateTimeOffset now)
    {
        var nowInTz = TimeZoneInfo.ConvertTime(now, _zoneInfo);
        return Evaluator.PreviousFrom(_data, nowInTz, _zoneInfo);
    }

    /// <summary>
    /// Checks if a datetime matches this schedule.
    /// </summary>
    /// <param name="dateTime">The datetime to check</param>
    /// <returns>True if the datetime matches</returns>
    public bool Matches(DateTimeOffset dateTime)
    {
        var dtInTz = TimeZoneInfo.ConvertTime(dateTime, _zoneInfo);
        return Evaluator.Matches(_data, dtInTz, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences starting after the given time.
    /// </summary>
    /// <param name="from">The reference time (exclusive)</param>
    /// <returns>An enumerable of occurrences</returns>
    public IEnumerable<DateTimeOffset> Occurrences(DateTimeOffset from)
    {
        var fromInTz = TimeZoneInfo.ConvertTime(from, _zoneInfo);
        return Evaluator.Occurrences(_data, fromInTz, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences where from &lt; occurrence &lt;= to.
    /// </summary>
    /// <param name="from">The start time (exclusive)</param>
    /// <param name="to">The end time (inclusive)</param>
    /// <returns>An enumerable of occurrences in the range</returns>
    public IEnumerable<DateTimeOffset> Between(DateTimeOffset from, DateTimeOffset to)
    {
        var fromInTz = TimeZoneInfo.ConvertTime(from, _zoneInfo);
        var toInTz = TimeZoneInfo.ConvertTime(to, _zoneInfo);
        return Evaluator.Between(_data, fromInTz, toInTz, _zoneInfo);
    }

    /// <summary>
    /// Converts this schedule to a 5-field cron expression.
    /// </summary>
    /// <returns>The cron expression</returns>
    /// <exception cref="HronException">If the schedule cannot be expressed as cron</exception>
    public string ToCron() => CronConverter.ToCron(_data);

    /// <summary>
    /// Returns the IANA timezone name, or null if not specified.
    /// </summary>
    public string? Timezone => string.IsNullOrEmpty(_data.Timezone) ? null : _data.Timezone;

    /// <summary>
    /// Returns the canonical string representation of this schedule.
    /// </summary>
    public override string ToString() => HronDisplay.Render(_data);

    /// <summary>
    /// Returns the underlying schedule data.
    /// </summary>
    public ScheduleData Data => _data;

    /// <summary>
    /// Resolve timezone, defaulting to UTC for deterministic behavior.
    /// </summary>
    private static TimeZoneInfo ResolveTimezone(string? tzName)
    {
        if (string.IsNullOrEmpty(tzName))
        {
            return TimeZoneInfo.Utc;
        }

        // Try IANA timezone ID first
        try
        {
            return TimeZoneInfo.FindSystemTimeZoneById(tzName);
        }
        catch (TimeZoneNotFoundException)
        {
            // On Windows, may need to try TZConvert or alternative ID
            // .NET 6+ should support IANA IDs on all platforms
            throw HronException.Parse($"unknown timezone: {tzName}", new Span(0, 0), tzName);
        }
    }
}
