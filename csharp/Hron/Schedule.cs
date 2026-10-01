using Hron.Ast;
using Hron.Cron;
using Hron.Eval;
using HronParser = Hron.Parser.Parser;
using HronDisplay = Hron.Display.Display;

namespace Hron;

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
    /// <exception cref="HronException">If the input is invalid</exception>
    public static Schedule Parse(string input)
    {
        var data = HronParser.Parse(input);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Converts a 5-field cron expression to a Schedule that fires at the same times.
    /// </summary>
    /// <exception cref="HronException">A cron error when the input is not valid cron or has no exact hron equivalent</exception>
    public static Schedule FromCron(string cronExpr)
    {
        var data = CronConverter.FromCron(cronExpr);
        var zoneInfo = ResolveTimezone(data.Timezone);
        return new Schedule(data, zoneInfo);
    }

    /// <summary>
    /// Validates an hron expression without throwing.
    /// </summary>
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
    /// <returns>The next occurrence, or null if none exists or now is outside the supported range</returns>
    public DateTimeOffset? NextFrom(DateTimeOffset now)
    {
        return Evaluator.NextFrom(_data, now, _zoneInfo);
    }

    /// <summary>
    /// Computes the next n occurrences strictly after the given time.
    /// </summary>
    /// <returns>A list of the next n occurrences, empty when now is outside the supported range</returns>
    public IReadOnlyList<DateTimeOffset> NextNFrom(DateTimeOffset now, int count)
    {
        return Evaluator.NextNFrom(_data, now, count, _zoneInfo);
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
    /// Returns the IANA timezone name in its canonical capitalization, or null if not specified.
    /// </summary>
    public string? Timezone => string.IsNullOrEmpty(_data.Timezone) ? null : _data.Timezone;

    /// <summary>
    /// Returns the canonical string representation of this schedule.
    /// </summary>
    public override string ToString() => HronDisplay.Render(_data);

    public ScheduleData Data => _data;

    /// <summary>
    /// UTC when unset, so results never depend on the host zone.
    /// </summary>
    private static TimeZoneInfo ResolveTimezone(string? tzName)
    {
        return string.IsNullOrEmpty(tzName) ? TimeZoneInfo.Utc : TimeZoneInfo.FindSystemTimeZoneById(tzName);
    }
}
