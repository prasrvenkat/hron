package io.hron.ast;

import java.util.List;

/**
 * Represents the complete parsed schedule with all clauses.
 *
 * @param expr the schedule expression
 * @param timezone the IANA timezone (may be null)
 * @param except the exception dates
 * @param until the until date (may be null)
 * @param anchor the anchor date for interval alignment (ISO string, may be null)
 * @param during the months during which the schedule applies
 */
public record ScheduleData(
    ScheduleExpr expr,
    String timezone,
    List<ExceptionSpec> except,
    UntilSpec until,
    String anchor,
    List<MonthName> during) {
  /** Creates a new ScheduleData with defensive copies of lists. */
  public ScheduleData {
    except = except == null ? List.of() : List.copyOf(except);
    during = during == null ? List.of() : List.copyOf(during);
  }

  /**
   * Creates a new ScheduleData with just the expression.
   *
   * @param expr the schedule expression
   * @return a new ScheduleData with default values for all clauses
   */
  public static ScheduleData of(ScheduleExpr expr) {
    return new ScheduleData(expr, null, List.of(), null, null, List.of());
  }

  /**
   * Returns a copy with the specified timezone.
   *
   * @param timezone the timezone
   * @return a new ScheduleData with the updated timezone
   */
  public ScheduleData withTimezone(String timezone) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  /**
   * Returns a copy with the specified exceptions.
   *
   * @param except the exception dates
   * @return a new ScheduleData with the updated exceptions
   */
  public ScheduleData withExcept(List<ExceptionSpec> except) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  /**
   * Returns a copy with the specified until date.
   *
   * @param until the until date
   * @return a new ScheduleData with the updated until date
   */
  public ScheduleData withUntil(UntilSpec until) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  /**
   * Returns a copy with the specified anchor date.
   *
   * @param anchor the anchor date (ISO string)
   * @return a new ScheduleData with the updated anchor
   */
  public ScheduleData withAnchor(String anchor) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  /**
   * Returns a copy with the specified during months.
   *
   * @param during the months
   * @return a new ScheduleData with the updated during clause
   */
  public ScheduleData withDuring(List<MonthName> during) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }
}
