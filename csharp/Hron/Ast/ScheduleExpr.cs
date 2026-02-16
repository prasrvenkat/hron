namespace Hron.Ast;

/// <summary>
/// Base interface for schedule expressions.
/// There are 6 types of schedule expressions:
/// - DayRepeat: "every day at 9:00"
/// - IntervalRepeat: "every 30 min from 9:00 to 17:00"
/// - WeekRepeat: "every 2 weeks on monday"
/// - MonthRepeat: "every month on the 1st" or "every month on the first monday"
/// - SingleDate: "on feb 14 at 9:00"
/// - YearRepeat: "every year on dec 25"
/// </summary>
public interface IScheduleExpr;
