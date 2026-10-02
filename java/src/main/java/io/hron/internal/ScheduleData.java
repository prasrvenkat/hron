package io.hron.internal;

import io.hron.ast.ExceptionSpec;
import io.hron.ast.MonthName;
import io.hron.ast.ScheduleExpr;
import io.hron.ast.UntilSpec;
import java.util.List;

public record ScheduleData(
    ScheduleExpr expression,
    String timezone,
    List<ExceptionSpec> except,
    UntilSpec until,
    String starting,
    List<MonthName> during) {
  public ScheduleData {
    except = except == null ? List.of() : List.copyOf(except);
    during = during == null ? List.of() : List.copyOf(during);
  }
}
