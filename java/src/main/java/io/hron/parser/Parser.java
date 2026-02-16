package io.hron.parser;

import io.hron.HronException;
import io.hron.Span;
import io.hron.ast.*;
import io.hron.lexer.Lexer;
import io.hron.lexer.Token;
import io.hron.lexer.TokenKind;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;

/** Recursive descent parser for hron expressions. */
public final class Parser {
  private final String input;
  private final List<Token> tokens;
  private int pos;

  private Parser(String input, List<Token> tokens) {
    this.input = input;
    this.tokens = tokens;
    this.pos = 0;
  }

  /**
   * Parses an hron expression into a ScheduleData.
   *
   * @param input the input string to parse
   * @return the parsed schedule data
   * @throws HronException if the input is invalid
   */
  public static ScheduleData parse(String input) throws HronException {
    if (input == null || input.trim().isEmpty()) {
      throw HronException.parse("empty input", new Span(0, 0), input, null);
    }

    List<Token> tokens = Lexer.tokenize(input);
    if (tokens.isEmpty()) {
      throw HronException.parse("empty input", new Span(0, 0), input, null);
    }

    return new Parser(input, tokens).parseSchedule();
  }

  private ScheduleData parseSchedule() throws HronException {
    ScheduleExpr expr = parseExpr();

    // Parse optional clauses in order: except, until, starting, during, in
    List<ExceptionSpec> except = List.of();
    UntilSpec until = null;
    String anchor = null;
    List<MonthName> during = List.of();
    String timezone = null;

    while (pos < tokens.size()) {
      Token tok = tokens.get(pos);
      switch (tok.kind()) {
        case EXCEPT -> {
          if (!except.isEmpty()) {
            throw parseError("duplicate except clause", tok.span());
          }
          if (until != null) {
            throw parseError("wrong clause order: until before except", tok.span());
          }
          if (anchor != null) {
            throw parseError("wrong clause order: starting before except", tok.span());
          }
          if (!during.isEmpty()) {
            throw parseError("wrong clause order: during before except", tok.span());
          }
          if (timezone != null) {
            throw parseError("wrong clause order: in before except", tok.span());
          }
          pos++;
          except = parseExceptions();
        }
        case UNTIL -> {
          if (until != null) {
            throw parseError("duplicate until clause", tok.span());
          }
          if (anchor != null) {
            throw parseError("wrong clause order: starting before until", tok.span());
          }
          if (!during.isEmpty()) {
            throw parseError("wrong clause order: during before until", tok.span());
          }
          if (timezone != null) {
            throw parseError("wrong clause order: in before until", tok.span());
          }
          pos++;
          until = parseUntil();
        }
        case STARTING -> {
          if (anchor != null) {
            throw parseError("duplicate starting clause", tok.span());
          }
          if (!during.isEmpty()) {
            throw parseError("wrong clause order: during before starting", tok.span());
          }
          if (timezone != null) {
            throw parseError("wrong clause order: in before starting", tok.span());
          }
          pos++;
          anchor = parseStarting();
        }
        case DURING -> {
          if (!during.isEmpty()) {
            throw parseError("duplicate during clause", tok.span());
          }
          if (timezone != null) {
            throw parseError("wrong clause order: in before during", tok.span());
          }
          pos++;
          during = parseDuring();
        }
        case IN -> {
          pos++;
          timezone = parseTimezone();
        }
        default -> throw parseError("unexpected token", tok.span());
      }
    }

    return new ScheduleData(expr, timezone, except, until, anchor, during);
  }

  private ScheduleExpr parseExpr() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input", endSpan());
    }

    return switch (tok.kind()) {
      case EVERY -> parseEveryExpr();
      case ON -> parseSingleDate();
      default -> throw parseError("expected 'every' or 'on'", tok.span());
    };
  }

  private ScheduleExpr parseEveryExpr() throws HronException {
    expect(TokenKind.EVERY);

    Token next = peek();
    if (next == null) {
      throw parseError("unexpected end of input after 'every'", endSpan());
    }

    return switch (next.kind()) {
      case NUMBER -> parseEveryNumber();
      case DAY, WEEKDAY, WEEKEND, DAY_NAME -> parseDayRepeat();
      case YEAR -> parseYearRepeat();
      case MONTH -> parseMonthRepeat();
      default -> throw parseError("unexpected token after 'every'", next.span());
    };
  }

  private ScheduleExpr parseEveryNumber() throws HronException {
    Token numTok = expect(TokenKind.NUMBER);
    int interval = numTok.numberVal();

    if (interval == 0) {
      throw parseError("zero interval", numTok.span());
    }

    Token next = peek();
    if (next == null) {
      throw parseError("unexpected end of input after number", endSpan());
    }

    return switch (next.kind()) {
      case INTERVAL_UNIT -> parseIntervalRepeat(interval);
      case DAY -> {
        pos++;
        // Normalize "every 1 day" -> "every day"
        var days = interval == 1 ? DayFilter.every() : null;
        var times = parseAtTimes();
        yield new DayRepeat(interval, days != null ? days : DayFilter.every(), times);
      }
      case WEEKS -> {
        pos++;
        expect(TokenKind.ON);
        var weekDays = parseDayList();
        var times = parseAtTimes();
        yield new WeekRepeat(interval, weekDays, times);
      }
      case MONTH -> {
        pos++;
        expect(TokenKind.ON);
        expect(TokenKind.THE);
        var target = parseMonthTarget();
        var times = parseAtTimes();
        yield new MonthRepeat(interval, target, times);
      }
      case YEAR -> {
        pos++;
        expect(TokenKind.ON);
        var target = parseYearTarget();
        var times = parseAtTimes();
        yield new YearRepeat(interval, target, times);
      }
      default ->
          throw parseError(
              "expected unit (min/hours/day/weeks/month/year) after number", next.span());
    };
  }

  private ScheduleExpr parseDayRepeat() throws HronException {
    DayFilter days = parseDayFilter();
    List<TimeOfDay> times = parseAtTimes();
    return new DayRepeat(1, days, times);
  }

  private DayFilter parseDayFilter() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input", endSpan());
    }

    return switch (tok.kind()) {
      case DAY -> {
        pos++;
        yield DayFilter.every();
      }
      case WEEKDAY -> {
        pos++;
        yield DayFilter.weekday();
      }
      case WEEKEND -> {
        pos++;
        yield DayFilter.weekend();
      }
      case DAY_NAME -> DayFilter.days(parseDayList());
      default -> throw parseError("expected day filter", tok.span());
    };
  }

  private List<Weekday> parseDayList() throws HronException {
    List<Weekday> days = new ArrayList<>();

    Token tok = expect(TokenKind.DAY_NAME);
    days.add(tok.dayNameVal());

    while (check(TokenKind.COMMA)) {
      pos++;
      tok = expect(TokenKind.DAY_NAME);
      days.add(tok.dayNameVal());
    }

    return days;
  }

  private ScheduleExpr parseIntervalRepeat(int interval) throws HronException {
    Token unitTok = expect(TokenKind.INTERVAL_UNIT);
    IntervalUnit unit = unitTok.unitVal();

    expect(TokenKind.FROM);
    TimeOfDay fromTime = parseTime();
    expect(TokenKind.TO);
    TimeOfDay toTime = parseTime();

    DayFilter dayFilter = null;
    if (check(TokenKind.ON)) {
      pos++;
      dayFilter = parseDayFilterForInterval();
    }

    return new IntervalRepeat(interval, unit, fromTime, toTime, dayFilter);
  }

  private DayFilter parseDayFilterForInterval() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'on'", endSpan());
    }

    return switch (tok.kind()) {
      case DAY -> {
        pos++;
        yield DayFilter.every();
      }
      case WEEKDAY -> {
        pos++;
        yield DayFilter.weekday();
      }
      case WEEKEND -> {
        pos++;
        yield DayFilter.weekend();
      }
      case DAY_NAME -> DayFilter.days(parseDayList());
      default -> throw parseError("expected day filter after 'on'", tok.span());
    };
  }

  private ScheduleExpr parseMonthRepeat() throws HronException {
    expect(TokenKind.MONTH);
    expect(TokenKind.ON);
    expect(TokenKind.THE);

    MonthTarget target = parseMonthTarget();
    List<TimeOfDay> times = parseAtTimes();

    return new MonthRepeat(1, target, times);
  }

  private MonthTarget parseMonthTarget() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input", endSpan());
    }

    if (tok.kind() == TokenKind.LAST) {
      pos++;
      Token next = peek();
      if (next != null && next.kind() == TokenKind.DAY) {
        pos++;
        return MonthTarget.lastDay();
      } else if (next != null && next.kind() == TokenKind.WEEKDAY) {
        pos++;
        return MonthTarget.lastWeekday();
      } else if (next != null && next.kind() == TokenKind.DAY_NAME) {
        Weekday weekday = next.dayNameVal();
        pos++;
        return MonthTarget.ordinalWeekday(OrdinalPosition.LAST, weekday);
      }
      throw parseError(
          "expected 'day', 'weekday', or day name after 'last'",
          next != null ? next.span() : endSpan());
    }

    // Check for ordinal + day_name (e.g., "first monday")
    if (tok.kind() == TokenKind.ORDINAL) {
      OrdinalPosition ordinal = tok.ordinalVal();
      pos++;
      Token dayTok = expect(TokenKind.DAY_NAME);
      Weekday weekday = dayTok.dayNameVal();
      return MonthTarget.ordinalWeekday(ordinal, weekday);
    }

    // Check for [next|previous] nearest weekday to <day>
    if (tok.kind() == TokenKind.NEXT
        || tok.kind() == TokenKind.PREVIOUS
        || tok.kind() == TokenKind.NEAREST) {
      return parseNearestWeekdayTarget();
    }

    // Parse day specs (single or range)
    List<DayOfMonthSpec> specs = parseDayOfMonthSpecs();
    return MonthTarget.days(specs);
  }

  /**
   * Parses [next|previous] nearest weekday to <ordinal_day>.
   *
   * @return a nearest weekday month target
   * @throws HronException if parsing fails
   */
  private MonthTarget parseNearestWeekdayTarget() throws HronException {
    // Optional direction: "next" or "previous"
    NearestDirection direction = null;
    Token tok = peek();
    if (tok != null && tok.kind() == TokenKind.NEXT) {
      pos++;
      direction = NearestDirection.NEXT;
    } else if (tok != null && tok.kind() == TokenKind.PREVIOUS) {
      pos++;
      direction = NearestDirection.PREVIOUS;
    }

    expect(TokenKind.NEAREST);
    expect(TokenKind.WEEKDAY);
    expect(TokenKind.TO);

    Token dayTok = expect(TokenKind.ORDINAL_NUMBER);
    int day = dayTok.numberVal();

    return MonthTarget.nearestWeekday(day, direction);
  }

  private List<DayOfMonthSpec> parseDayOfMonthSpecs() throws HronException {
    List<DayOfMonthSpec> specs = new ArrayList<>();
    specs.add(parseDayOfMonthSpec());

    while (check(TokenKind.COMMA)) {
      pos++;
      specs.add(parseDayOfMonthSpec());
    }

    return specs;
  }

  private DayOfMonthSpec parseDayOfMonthSpec() throws HronException {
    Token tok = expect(TokenKind.ORDINAL_NUMBER);
    int start = tok.numberVal();

    if (check(TokenKind.TO)) {
      pos++;
      Token endTok = expect(TokenKind.ORDINAL_NUMBER);
      return DayOfMonthSpec.range(start, endTok.numberVal());
    }

    return DayOfMonthSpec.single(start);
  }

  private ScheduleExpr parseYearRepeat() throws HronException {
    expect(TokenKind.YEAR);
    expect(TokenKind.ON);

    YearTarget target = parseYearTarget();
    List<TimeOfDay> times = parseAtTimes();

    return new YearRepeat(1, target, times);
  }

  private YearTarget parseYearTarget() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'on'", endSpan());
    }

    // Check for "the" (ordinal weekday, day of month, or last weekday)
    if (tok.kind() == TokenKind.THE) {
      pos++;
      return parseYearTargetAfterThe();
    }

    // Named date: month day (e.g., dec 25)
    Token monthTok = expect(TokenKind.MONTH_NAME);
    Token dayTok = expect(TokenKind.NUMBER);
    return YearTarget.date(monthTok.monthNameVal(), dayTok.numberVal());
  }

  private YearTarget parseYearTargetAfterThe() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'the'", endSpan());
    }

    // "the last ..."
    if (tok.kind() == TokenKind.LAST) {
      pos++;
      Token next = peek();
      if (next != null && next.kind() == TokenKind.DAY_NAME) {
        // "the last friday of month"
        Weekday weekday = tokens.get(pos++).dayNameVal();
        expect(TokenKind.OF);
        Token monthTok = expect(TokenKind.MONTH_NAME);
        return YearTarget.ordinalWeekday(OrdinalPosition.LAST, weekday, monthTok.monthNameVal());
      } else if (next != null && next.kind() == TokenKind.WEEKDAY) {
        // "the last weekday of month"
        pos++;
        expect(TokenKind.OF);
        Token monthTok = expect(TokenKind.MONTH_NAME);
        return YearTarget.lastWeekday(monthTok.monthNameVal());
      }
      throw parseError(
          "expected day name or 'weekday' after 'last'", next != null ? next.span() : endSpan());
    }

    // "the first/second/... weekday of month"
    if (tok.kind() == TokenKind.ORDINAL) {
      OrdinalPosition ordinal = tokens.get(pos++).ordinalVal();
      Token dayTok = expect(TokenKind.DAY_NAME);
      expect(TokenKind.OF);
      Token monthTok = expect(TokenKind.MONTH_NAME);
      return YearTarget.ordinalWeekday(ordinal, dayTok.dayNameVal(), monthTok.monthNameVal());
    }

    // "the 15th of month"
    if (tok.kind() == TokenKind.ORDINAL_NUMBER) {
      int day = tokens.get(pos++).numberVal();
      expect(TokenKind.OF);
      Token monthTok = expect(TokenKind.MONTH_NAME);
      return YearTarget.dayOfMonth(day, monthTok.monthNameVal());
    }

    throw parseError("expected ordinal, ordinal number, or 'last' after 'the'", tok.span());
  }

  private ScheduleExpr parseSingleDate() throws HronException {
    expect(TokenKind.ON);

    DateSpec dateSpec = parseDateSpec();
    List<TimeOfDay> times = parseAtTimes();

    return new SingleDate(dateSpec, times);
  }

  private void validateIsoDate(String dateStr, Span span) throws HronException {
    try {
      LocalDate.parse(dateStr);
    } catch (DateTimeParseException e) {
      throw parseError("invalid date: " + dateStr, span);
    }
  }

  private DateSpec parseDateSpec() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input", endSpan());
    }

    if (tok.kind() == TokenKind.ISO_DATE) {
      validateIsoDate(tok.isoDateVal(), tok.span());
      pos++;
      return DateSpec.iso(tok.isoDateVal());
    }

    Token monthTok = expect(TokenKind.MONTH_NAME);
    Token dayTok = expect(TokenKind.NUMBER);
    return DateSpec.named(monthTok.monthNameVal(), dayTok.numberVal());
  }

  private List<TimeOfDay> parseAtTimes() throws HronException {
    expect(TokenKind.AT);
    return parseTimeList();
  }

  private List<TimeOfDay> parseTimeList() throws HronException {
    List<TimeOfDay> times = new ArrayList<>();
    times.add(parseTime());

    while (check(TokenKind.COMMA)) {
      pos++;
      times.add(parseTime());
    }

    return times;
  }

  private TimeOfDay parseTime() throws HronException {
    Token tok = expect(TokenKind.TIME);
    return new TimeOfDay(tok.timeHour(), tok.timeMinute());
  }

  private List<ExceptionSpec> parseExceptions() throws HronException {
    List<ExceptionSpec> exceptions = new ArrayList<>();

    exceptions.add(parseExceptionSpec());
    while (check(TokenKind.COMMA)) {
      pos++;
      exceptions.add(parseExceptionSpec());
    }

    return exceptions;
  }

  private ExceptionSpec parseExceptionSpec() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'except'", endSpan());
    }

    if (tok.kind() == TokenKind.ISO_DATE) {
      validateIsoDate(tok.isoDateVal(), tok.span());
      pos++;
      return ExceptionSpec.iso(tok.isoDateVal());
    }

    Token monthTok = expect(TokenKind.MONTH_NAME);
    Token dayTok = expect(TokenKind.NUMBER);
    return ExceptionSpec.named(monthTok.monthNameVal(), dayTok.numberVal());
  }

  private UntilSpec parseUntil() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'until'", endSpan());
    }

    if (tok.kind() == TokenKind.ISO_DATE) {
      validateIsoDate(tok.isoDateVal(), tok.span());
      pos++;
      return UntilSpec.iso(tok.isoDateVal());
    }

    Token monthTok = expect(TokenKind.MONTH_NAME);
    Token dayTok = expect(TokenKind.NUMBER);
    return UntilSpec.named(monthTok.monthNameVal(), dayTok.numberVal());
  }

  private String parseStarting() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'starting'", endSpan());
    }

    if (tok.kind() == TokenKind.ISO_DATE) {
      validateIsoDate(tok.isoDateVal(), tok.span());
      pos++;
      return tok.isoDateVal();
    }

    throw parseError("starting only accepts ISO dates", tok.span());
  }

  private List<MonthName> parseDuring() throws HronException {
    List<MonthName> months = new ArrayList<>();

    Token tok = expect(TokenKind.MONTH_NAME);
    months.add(tok.monthNameVal());

    while (check(TokenKind.COMMA)) {
      pos++;
      tok = expect(TokenKind.MONTH_NAME);
      months.add(tok.monthNameVal());
    }

    return months;
  }

  private String parseTimezone() throws HronException {
    Token tok = peek();
    if (tok == null || tok.kind() != TokenKind.TIMEZONE) {
      throw parseError("expected timezone after 'in'", tok != null ? tok.span() : endSpan());
    }
    pos++;
    return tok.timezoneVal();
  }

  // Helper methods

  private Token peek() {
    return pos < tokens.size() ? tokens.get(pos) : null;
  }

  private boolean check(TokenKind kind) {
    Token tok = peek();
    return tok != null && tok.kind() == kind;
  }

  private Token expect(TokenKind kind) throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("expected " + kind + " but reached end of input", endSpan());
    }
    if (tok.kind() != kind) {
      throw parseError("expected " + kind + " but got " + tok.kind(), tok.span());
    }
    pos++;
    return tok;
  }

  private Span endSpan() {
    if (tokens.isEmpty()) {
      return new Span(0, 0);
    }
    Span lastSpan = tokens.getLast().span();
    return new Span(lastSpan.end(), lastSpan.end());
  }

  private HronException parseError(String message, Span span) {
    return HronException.parse(message, span, input, null);
  }
}
