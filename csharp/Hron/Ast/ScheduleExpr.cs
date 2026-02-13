namespace Hron.Ast;

/// <summary>
/// Base interface for schedule expressions.
/// There are 7 types of schedule expressions:
/// - DayRepeat: "every day at 9:00"
/// - IntervalRepeat: "every 30 min from 9:00 to 17:00"
/// - WeekRepeat: "every 2 weeks on monday"
/// - MonthRepeat: "every month on the 1st"
/// - OrdinalRepeat: "first monday of every month"
/// - SingleDate: "on feb 14 at 9:00"
/// - YearRepeat: "every year on dec 25"
/// </summary>
public interface IScheduleExpr;
