package io.hron.parser;

import io.hron.HronException;
import io.hron.Span;
import io.hron.ast.*;
import io.hron.lexer.Lexer;
import io.hron.lexer.Token;
import io.hron.lexer.TokenKind;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

public final class Parser {
  // spec/README.md "Parse-time validation": UTC or an IANA Area/Location name, in any case, but
  // not the SystemV/, posix/ and right/ build directories.
  private static final Map<String, String> TIMEZONES =
      ZoneId.getAvailableZoneIds().stream()
          .filter(
              id ->
                  id.equals("UTC")
                      || (id.contains("/")
                          && !id.startsWith("SystemV/")
                          && !id.startsWith("posix/")
                          && !id.startsWith("right/")))
          .collect(Collectors.toMap(id -> id.toLowerCase(Locale.ROOT), Function.identity()));

  private final String input;
  private final List<Token> tokens;
  private int pos;

  private Parser(String input, List<Token> tokens) {
    this.input = input;
    this.tokens = tokens;
    this.pos = 0;
  }

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

    List<ExceptionSpec> except = List.of();
    UntilSpec until = null;
    Span untilSpan = null;
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
          untilSpan = new Span(tok.span().start(), tokens.get(pos - 1).span().end());
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

    if (until != null && until.kind() == UntilSpec.Kind.NAMED && anchor == null) {
      throw HronException.parse(
          "named until date needs a starting date to know its year (or use an ISO until date)",
          untilSpan,
          input,
          "until " + until.month() + " " + until.day() + " starting YYYY-MM-DD");
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
      case WEEKS -> parseWeekRepeat();
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
    Token toTok = peek();
    TimeOfDay toTime = parseTime();
    if (fromTime.totalMinutes() > toTime.totalMinutes()) {
      throw parseError(
          "invalid time range: from "
              + fromTime
              + " is later than to "
              + toTime
              + "; a window cannot cross midnight",
          toTok.span());
    }

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

  private ScheduleExpr parseWeekRepeat() throws HronException {
    expect(TokenKind.WEEKS);
    expect(TokenKind.ON);

    var weekDays = parseDayList();
    var times = parseAtTimes();

    return new WeekRepeat(1, weekDays, times);
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

    if (tok.kind() == TokenKind.ORDINAL) {
      OrdinalPosition ordinal = tok.ordinalVal();
      pos++;
      Token dayTok = expect(TokenKind.DAY_NAME);
      Weekday weekday = dayTok.dayNameVal();
      return MonthTarget.ordinalWeekday(ordinal, weekday);
    }

    if (tok.kind() == TokenKind.NEXT
        || tok.kind() == TokenKind.PREVIOUS
        || tok.kind() == TokenKind.NEAREST) {
      return parseNearestWeekdayTarget();
    }

    List<DayOfMonthSpec> specs = parseDayOfMonthSpecs();
    return MonthTarget.days(specs);
  }

  private MonthTarget parseNearestWeekdayTarget() throws HronException {
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
    if (day < 1 || day > 31) {
      throw parseError("invalid day number " + day + " (must be 1-31)", dayTok.span());
    }

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

    if (start < 1 || start > 31) {
      throw parseError("invalid day number " + start + " (must be 1-31)", tok.span());
    }

    if (check(TokenKind.TO)) {
      pos++;
      Token endTok = expect(TokenKind.ORDINAL_NUMBER);
      int end = endTok.numberVal();
      if (end < 1 || end > 31) {
        throw parseError("invalid day number " + end + " (must be 1-31)", endTok.span());
      }
      if (start > end) {
        throw parseError(
            "invalid day range: " + start + " to " + end + " (start must be <= end)", tok.span());
      }
      return DayOfMonthSpec.range(start, end);
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

    if (tok.kind() == TokenKind.THE) {
      pos++;
      return parseYearTargetAfterThe();
    }

    Token monthTok = expect(TokenKind.MONTH_NAME);
    Token dayTok = parseDayNumber();
    validateNamedDate(monthTok.monthNameVal(), dayTok.numberVal(), dayTok.span());
    return YearTarget.date(monthTok.monthNameVal(), dayTok.numberVal());
  }

  private YearTarget parseYearTargetAfterThe() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("unexpected end of input after 'the'", endSpan());
    }

    if (tok.kind() == TokenKind.LAST) {
      pos++;
      Token next = peek();
      if (next != null && next.kind() == TokenKind.DAY_NAME) {
        Weekday weekday = tokens.get(pos++).dayNameVal();
        expect(TokenKind.OF);
        Token monthTok = expect(TokenKind.MONTH_NAME);
        return YearTarget.ordinalWeekday(OrdinalPosition.LAST, weekday, monthTok.monthNameVal());
      } else if (next != null && next.kind() == TokenKind.WEEKDAY) {
        pos++;
        expect(TokenKind.OF);
        Token monthTok = expect(TokenKind.MONTH_NAME);
        return YearTarget.lastWeekday(monthTok.monthNameVal());
      }
      throw parseError(
          "expected day name or 'weekday' after 'last'", next != null ? next.span() : endSpan());
    }

    if (tok.kind() == TokenKind.ORDINAL) {
      OrdinalPosition ordinal = tokens.get(pos++).ordinalVal();
      Token dayTok = expect(TokenKind.DAY_NAME);
      expect(TokenKind.OF);
      Token monthTok = expect(TokenKind.MONTH_NAME);
      return YearTarget.ordinalWeekday(ordinal, dayTok.dayNameVal(), monthTok.monthNameVal());
    }

    if (tok.kind() == TokenKind.ORDINAL_NUMBER) {
      int day = tokens.get(pos++).numberVal();
      expect(TokenKind.OF);
      Token monthTok = expect(TokenKind.MONTH_NAME);
      validateNamedDate(monthTok.monthNameVal(), day, tok.span());
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
      if (LocalDate.parse(dateStr).getYear() < 1) {
        throw parseError("invalid date: " + dateStr + " (year must be 0001-9999)", span);
      }
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
    Token dayTok = parseDayNumber();
    validateNamedDate(monthTok.monthNameVal(), dayTok.numberVal(), dayTok.span());
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
    Token dayTok = parseDayNumber();
    validateNamedDate(monthTok.monthNameVal(), dayTok.numberVal(), dayTok.span());
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
    Token dayTok = parseDayNumber();
    validateNamedDate(monthTok.monthNameVal(), dayTok.numberVal(), dayTok.span());
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
    String name = tok.timezoneVal();
    // Timezone names are ASCII; Unicode lowercasing would map a Kelvin sign to k.
    boolean ascii = name.chars().allMatch(c -> c < 128);
    String canonical = ascii ? TIMEZONES.get(name.toLowerCase(Locale.ROOT)) : null;
    if (canonical == null) {
      throw parseError(
          "unknown timezone '" + name + "'; use UTC or an IANA name such as America/New_York",
          tok.span());
    }
    return canonical;
  }

  private static final int[] MAX_DAYS = {0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

  private void validateNamedDate(MonthName month, int day, Span span) throws HronException {
    int maxDay = MAX_DAYS[month.number()];
    if (day < 1 || day > maxDay) {
      throw parseError("invalid day " + day + " for " + month + " (max " + maxDay + ")", span);
    }
  }

  private Token parseDayNumber() throws HronException {
    Token tok = peek();
    if (tok == null) {
      throw parseError("expected day number but reached end of input", endSpan());
    }
    if (tok.kind() != TokenKind.NUMBER && tok.kind() != TokenKind.ORDINAL_NUMBER) {
      throw parseError("expected day number but got " + tok.kind(), tok.span());
    }
    int day = tok.numberVal();
    if (day < 1 || day > 31) {
      throw parseError("invalid day number " + day + " (must be 1-31)", tok.span());
    }
    pos++;
    return tok;
  }

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
