package io.hron.ast;

import java.util.List;

/**
 * @param timezone the IANA name, or null for UTC
 * @param anchor the {@code starting} date as YYYY-MM-DD, or null
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
}
