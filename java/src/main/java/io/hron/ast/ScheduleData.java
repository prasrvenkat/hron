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
  /** Null {@code except} and {@code during} become empty lists. */
  public ScheduleData {
    except = except == null ? List.of() : List.copyOf(except);
    during = during == null ? List.of() : List.copyOf(during);
  }

  public static ScheduleData of(ScheduleExpr expr) {
    return new ScheduleData(expr, null, List.of(), null, null, List.of());
  }

  public ScheduleData withTimezone(String timezone) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  public ScheduleData withExcept(List<ExceptionSpec> except) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  public ScheduleData withUntil(UntilSpec until) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  public ScheduleData withAnchor(String anchor) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  public ScheduleData withDuring(List<MonthName> during) {
    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }
}
