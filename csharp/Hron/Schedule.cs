using Hron.Ast;
using Hron.Cron;
using Hron.Eval;
using HronParser = Hron.Parser.Parser;
using HronDisplay = Hron.Display.Display;

namespace Hron;

/// <summary>
/// The main entry point for parsing and evaluating hron schedule expressions.
/// </summary>
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
    /// Computes the next occurrence strictly after the given time.
    /// </summary>
    /// <param name="now">The reference time</param>
    /// <returns>The next occurrence, or null if none exists or now is outside the supported range</returns>
    public DateTimeOffset? NextFrom(DateTimeOffset now)
    {
        return Evaluator.NextFrom(_data, now, _zoneInfo);
    }

    /// <summary>
    /// Computes the next n occurrences strictly after the given time.
    /// </summary>
    /// <param name="now">The reference time</param>
    /// <param name="count">The number of occurrences to compute</param>
    /// <returns>A list of the next n occurrences, empty when now is outside the supported range</returns>
    public IReadOnlyList<DateTimeOffset> NextNFrom(DateTimeOffset now, int count)
    {
        return Evaluator.NextNFrom(_data, now, count, _zoneInfo);
    }

    /// <summary>
    /// Computes the most recent occurrence strictly before the given time.
    /// </summary>
    /// <param name="now">The reference time (exclusive upper bound)</param>
    /// <returns>The previous occurrence, or null if none exists or now is outside the supported range</returns>
    public DateTimeOffset? PreviousFrom(DateTimeOffset now)
    {
        return Evaluator.PreviousFrom(_data, now, _zoneInfo);
    }

    /// <summary>
    /// Checks if the minute containing a datetime is an occurrence of this schedule.
    /// </summary>
    /// <param name="dateTime">The datetime to check; its seconds are ignored</param>
    /// <returns>True if the start of that minute is an occurrence; false outside the supported range</returns>
    public bool Matches(DateTimeOffset dateTime)
    {
        return Evaluator.Matches(_data, dateTime, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences strictly after the given time.
    /// </summary>
    /// <param name="from">The reference time (exclusive)</param>
    /// <returns>An enumerable of occurrences, empty when from is outside the supported range</returns>
    public IEnumerable<DateTimeOffset> Occurrences(DateTimeOffset from)
    {
        return Evaluator.Occurrences(_data, from, _zoneInfo);
    }

    /// <summary>
    /// Returns a lazy enumerable of occurrences where from &lt; occurrence &lt;= to.
    /// </summary>
    /// <param name="from">The start time (exclusive)</param>
    /// <param name="to">The end time (inclusive)</param>
    /// <returns>An enumerable of occurrences in the range, empty when either bound is outside the supported range</returns>
    public IEnumerable<DateTimeOffset> Between(DateTimeOffset from, DateTimeOffset to)
    {
        return Evaluator.Between(_data, from, to, _zoneInfo);
    }

    /// <summary>
    /// Converts this schedule to a 5-field cron expression.
    /// </summary>
    /// <returns>The cron expression</returns>
    /// <exception cref="HronException">If the schedule cannot be expressed as cron</exception>
    public string ToCron() => CronConverter.ToCron(_data);

    /// <summary>
    /// Returns the IANA timezone name in its canonical capitalization, or null if not specified.
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
        return string.IsNullOrEmpty(tzName) ? TimeZoneInfo.Utc : TimeZoneInfo.FindSystemTimeZoneById(tzName);
    }
}
