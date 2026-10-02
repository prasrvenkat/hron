package io.hron.internal.parser;

import io.hron.HronException;
import io.hron.Span;
import io.hron.ast.*;
import io.hron.internal.ScheduleData;
import io.hron.internal.lexer.Lexer;
import io.hron.internal.lexer.Token;
import io.hron.internal.lexer.TokenKind;
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
  /**
   * The {@code {what}} of each {@code expected {what}, got ...} error, one per phrase in the
   * position table of spec/README.md, "Parse errors".
   */
  private static final class Expected {
    static final String EVERY_OR_ON = "'every' or 'on'";
    static final String REPEATER =
        "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number";
    static final String UNIT = "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')";
    static final String AT = "'at'";
    static final String TIME = "a time (HH:MM)";
    static final String FROM = "'from'";
    static final String TO = "'to'";
    static final String DAY_TARGET = "'day', 'weekday', 'weekend' or a day name";
    static final String ON = "'on'";
    static final String DAY_NAME = "a day name";
    static final String THE = "'the'";
    static final String MONTH_TARGET =
        "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'";
    static final String MONTH_LAST = "'day', 'weekday' or a day name";
    static final String NEAREST = "'nearest'";
    static final String WEEKDAY = "'weekday'";
    static final String DAY_OF_MONTH = "a day such as 15th";
    static final String YEAR_TARGET = "a month name or 'the'";
    static final String YEAR_THE = "a day such as 15th, 'last' or an ordinal such as 'first'";
    static final String YEAR_LAST = "'weekday' or a day name";
    static final String OF = "'of'";
    static final String MONTH_NAME = "a month name";
    static final String DAY_NUMBER = "a day number";
    static final String DATE = "a date (YYYY-MM-DD, or a month and day)";
    static final String ISO_DATE = "a date (YYYY-MM-DD)";
    static final String TIMEZONE = "a timezone";
  }

  private static final List<TokenKind> CLAUSE_ORDER =
      List.of(
          TokenKind.EXCEPT, TokenKind.UNTIL, TokenKind.STARTING, TokenKind.DURING, TokenKind.IN);

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

  private static final int[] MAX_DAYS = {0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

  private final String input;
  private final List<Token> tokens;
  private int pos;
  private int untilStart;
  private int untilEnd;

  private Parser(String input, List<Token> tokens) {
    this.input = input;
    this.tokens = tokens;
  }

  public static ScheduleData parse(String input) throws HronException {
    List<Token> tokens = Lexer.tokenize(input);
    if (tokens.isEmpty()) {
      throw HronException.parse("empty expression", new Span(0, 0), input, null);
    }
    Parser parser = new Parser(input, tokens);
    ScheduleExpr expr = parser.parseExpression();
    ScheduleData schedule = parser.parseClauses(expr);
    if (parser.peek() != null) {
      throw parser.leftover(schedule);
    }
    // spec/README.md, "Parse errors": every other error wins over a named until without starting.
    parser.checkNamedUntil(schedule);
    return schedule;
  }

  private TokenKind peekKind() {
    Token token = peek();
    return token == null ? null : token.kind();
  }

  private Token peek() {
    return pos < tokens.size() ? tokens.get(pos) : null;
  }

  private boolean at(TokenKind kind) {
    return peekKind() == kind;
  }

  private Token advance() {
    return tokens.get(pos++);
  }

  private Token previous() {
    return tokens.get(pos - 1);
  }

  private boolean eat(TokenKind kind) {
    boolean found = at(kind);
    if (found) {
      pos++;
    }
    return found;
  }

  private void expect(TokenKind kind, String what) throws HronException {
    if (!eat(kind)) {
      throw expected(what);
    }
  }

  private String text(Token token) {
    return input.substring(token.start(), token.end());
  }

  private HronException error(String message, int start, int end) {
    return HronException.parse(message, Lexer.span(input, start, end), input, null);
  }

  private HronException error(String message, Token token) {
    return error(message, token.start(), token.end());
  }

  private HronException expected(String what) {
    Token token = peek();
    if (token != null) {
      return error("expected " + what + ", got '" + text(token) + "'", token);
    }
    int end = tokens.getLast().end();
    return error("expected " + what + ", got end of input", end, end);
  }

  private ScheduleExpr parseExpression() throws HronException {
    if (eat(TokenKind.EVERY)) {
      return parseEvery();
    }
    if (eat(TokenKind.ON)) {
      return parseOn();
    }
    throw expected(Expected.EVERY_OR_ON);
  }

  private ScheduleData parseClauses(ScheduleExpr expr) throws HronException {
    List<ExceptionSpec> except = List.of();
    UntilSpec until = null;
    String starting = null;
    List<MonthName> during = List.of();
    String timezone = null;

    if (eat(TokenKind.EXCEPT)) {
      except = parseExceptionList();
    }

    if (at(TokenKind.UNTIL)) {
      untilStart = advance().start();
      DateSpec date = parseDate();
      until =
          date.kind() == DateSpec.Kind.ISO
              ? UntilSpec.iso(date.date())
              : UntilSpec.named(date.month(), date.day());
      untilEnd = previous().end();
    }

    if (eat(TokenKind.STARTING)) {
      if (!at(TokenKind.ISO_DATE)) {
        throw expected(Expected.ISO_DATE);
      }
      starting = isoDate(advance());
    }

    if (eat(TokenKind.DURING)) {
      during = parseMonthList();
    }

    if (eat(TokenKind.IN)) {
      if (!at(TokenKind.TIMEZONE)) {
        throw expected(Expected.TIMEZONE);
      }
      timezone = timezone(advance());
    }

    return new ScheduleData(expr, timezone, except, until, starting, during);
  }

  private HronException leftover(ScheduleData schedule) {
    Token token = peek();
    // Every clause holds at least one item, so a clause was read exactly when its field is set.
    boolean[] read = {
      !schedule.except().isEmpty(),
      schedule.until() != null,
      schedule.starting() != null,
      !schedule.during().isEmpty(),
      schedule.timezone() != null
    };
    int clause = CLAUSE_ORDER.indexOf(token.kind());
    int lastRead = -1;
    for (int i = 0; i < read.length; i++) {
      if (read[i]) {
        lastRead = i;
      }
    }
    String message;
    if (clause >= 0 && read[clause]) {
      message = "duplicate '" + keyword(clause) + "' clause";
    } else if (clause >= 0 && lastRead >= 0) {
      message = "'" + keyword(clause) + "' must come before '" + keyword(lastRead) + "'";
    } else {
      message = "unexpected '" + text(token) + "' after the schedule";
    }
    return error(message, token);
  }

  private static String keyword(int clause) {
    return CLAUSE_ORDER.get(clause).name().toLowerCase(Locale.ROOT);
  }

  private void checkNamedUntil(ScheduleData schedule) throws HronException {
    UntilSpec until = schedule.until();
    if (until == null || until.kind() != UntilSpec.Kind.NAMED || schedule.starting() != null) {
      return;
    }
    String date = until.month() + " " + until.day();
    throw HronException.parse(
        "until " + date + " has no year: add a starting date, or use an ISO date",
        Lexer.span(input, untilStart, untilEnd),
        input,
        "until " + date + " starting YYYY-MM-DD");
  }

  private List<ExceptionSpec> parseExceptionList() throws HronException {
    List<ExceptionSpec> exceptions = new ArrayList<>();
    do {
      DateSpec date = parseDate();
      exceptions.add(
          date.kind() == DateSpec.Kind.ISO
              ? ExceptionSpec.iso(date.date())
              : ExceptionSpec.named(date.month(), date.day()));
    } while (eat(TokenKind.COMMA));
    return exceptions;
  }

  private DateSpec parseDate() throws HronException {
    if (at(TokenKind.ISO_DATE)) {
      return DateSpec.iso(isoDate(advance()));
    }
    if (at(TokenKind.MONTH_NAME)) {
      MonthName month = advance().monthNameVal();
      return DateSpec.named(month, parseDayOf(month));
    }
    throw expected(Expected.DATE);
  }

  private String isoDate(Token token) throws HronException {
    String date = text(token);
    if (!isCalendarDate(date)) {
      throw error("date must be a calendar date from 0001-01-01 to 9999-12-31, got " + date, token);
    }
    return date;
  }

  private static boolean isCalendarDate(String date) {
    try {
      return LocalDate.parse(date).getYear() >= 1;
    } catch (DateTimeParseException e) {
      return false;
    }
  }

  private String timezone(Token token) throws HronException {
    String name = text(token);
    // Timezone names are ASCII; Unicode lowercasing would map a Kelvin sign to k.
    boolean ascii = name.chars().allMatch(c -> c < 128);
    String canonical = ascii ? TIMEZONES.get(name.toLowerCase(Locale.ROOT)) : null;
    if (canonical == null) {
      throw error(
          "timezone must be UTC or an Area/Location name such as America/New_York, got " + name,
          token);
    }
    return canonical;
  }

  private ScheduleExpr parseEvery() throws HronException {
    return switch (peekKind()) {
      case DAY -> {
        advance();
        yield parseDayRepeat(1, DayFilter.every());
      }
      case WEEKDAY -> {
        advance();
        yield parseDayRepeat(1, DayFilter.weekday());
      }
      case WEEKEND -> {
        advance();
        yield parseDayRepeat(1, DayFilter.weekend());
      }
      case DAY_NAME -> parseDayRepeat(1, DayFilter.days(parseDayList()));
      case WEEKS -> {
        advance();
        yield parseWeekRepeat(1);
      }
      case MONTH -> {
        advance();
        yield parseMonthRepeat(1);
      }
      case YEAR -> {
        advance();
        yield parseYearRepeat(1);
      }
      case NUMBER -> parseNumberRepeat();
      case null, default -> throw expected(Expected.REPEATER);
    };
  }

  private ScheduleExpr parseDayRepeat(int interval, DayFilter days) throws HronException {
    expect(TokenKind.AT, Expected.AT);
    return new DayRepeat(interval, days, parseTimeList());
  }

  private ScheduleExpr parseNumberRepeat() throws HronException {
    Token number = advance();
    int interval = number.numberVal();
    if (interval == 0) {
      throw error("interval must be 1-2147483647, got " + text(number), number);
    }

    return switch (peekKind()) {
      case WEEKS -> {
        advance();
        yield parseWeekRepeat(interval);
      }
      case INTERVAL_UNIT -> parseIntervalRepeat(interval, advance().unitVal());
      case DAY -> {
        advance();
        yield parseDayRepeat(interval, DayFilter.every());
      }
      case MONTH -> {
        advance();
        yield parseMonthRepeat(interval);
      }
      case YEAR -> {
        advance();
        yield parseYearRepeat(interval);
      }
      case null, default -> throw expected(Expected.UNIT);
    };
  }

  private ScheduleExpr parseIntervalRepeat(int interval, IntervalUnit unit) throws HronException {
    expect(TokenKind.FROM, Expected.FROM);
    TimeOfDay from = parseTime();
    Token fromToken = previous();
    expect(TokenKind.TO, Expected.TO);
    TimeOfDay to = parseTime();
    Token toToken = previous();
    if (from.totalMinutes() > to.totalMinutes()) {
      throw error(
          "time window must not run backwards: "
              + text(fromToken)
              + " to "
              + text(toToken)
              + " (a window cannot cross midnight)",
          fromToken.start(),
          toToken.end());
    }

    DayFilter dayFilter = eat(TokenKind.ON) ? parseDayTarget() : null;
    return new IntervalRepeat(interval, unit, from, to, dayFilter);
  }

  private ScheduleExpr parseWeekRepeat(int interval) throws HronException {
    expect(TokenKind.ON, Expected.ON);
    List<Weekday> days = parseDayList();
    expect(TokenKind.AT, Expected.AT);
    return new WeekRepeat(interval, days, parseTimeList());
  }

  private ScheduleExpr parseMonthRepeat(int interval) throws HronException {
    expect(TokenKind.ON, Expected.ON);
    expect(TokenKind.THE, Expected.THE);

    MonthTarget target =
        switch (peekKind()) {
          case LAST -> {
            advance();
            yield parseMonthLast();
          }
          case ORDINAL -> {
            OrdinalPosition ordinal = advance().ordinalVal();
            yield MonthTarget.ordinalWeekday(ordinal, parseDayName());
          }
          case ORDINAL_NUMBER -> MonthTarget.days(parseOrdinalDayList());
          case NEXT, PREVIOUS, NEAREST -> parseNearestWeekdayTarget();
          case null, default -> throw expected(Expected.MONTH_TARGET);
        };

    expect(TokenKind.AT, Expected.AT);
    return new MonthRepeat(interval, target, parseTimeList());
  }

  private MonthTarget parseMonthLast() throws HronException {
    MonthTarget target =
        switch (peekKind()) {
          case DAY -> MonthTarget.lastDay();
          case WEEKDAY -> MonthTarget.lastWeekday();
          case DAY_NAME -> MonthTarget.ordinalWeekday(OrdinalPosition.LAST, peek().dayNameVal());
          case null, default -> throw expected(Expected.MONTH_LAST);
        };
    advance();
    return target;
  }

  private MonthTarget parseNearestWeekdayTarget() throws HronException {
    NearestDirection direction = null;
    if (eat(TokenKind.NEXT)) {
      direction = NearestDirection.NEXT;
    } else if (eat(TokenKind.PREVIOUS)) {
      direction = NearestDirection.PREVIOUS;
    }
    expect(TokenKind.NEAREST, Expected.NEAREST);
    expect(TokenKind.WEEKDAY, Expected.WEEKDAY);
    expect(TokenKind.TO, Expected.TO);
    return MonthTarget.nearestWeekday(parseOrdinalDay(), direction);
  }

  private List<DayOfMonthSpec> parseOrdinalDayList() throws HronException {
    List<DayOfMonthSpec> specs = new ArrayList<>();
    do {
      specs.add(parseOrdinalDaySpec());
    } while (eat(TokenKind.COMMA));
    return specs;
  }

  private DayOfMonthSpec parseOrdinalDaySpec() throws HronException {
    int start = parseOrdinalDay();
    Token startToken = previous();
    if (!eat(TokenKind.TO)) {
      return DayOfMonthSpec.single(start);
    }
    int end = parseOrdinalDay();
    Token endToken = previous();
    if (start > end) {
      throw error(
          "day range must not run backwards: " + text(startToken) + " to " + text(endToken),
          startToken.start(),
          endToken.end());
    }
    return DayOfMonthSpec.range(start, end);
  }

  private int parseOrdinalDay() throws HronException {
    if (!at(TokenKind.ORDINAL_NUMBER)) {
      throw expected(Expected.DAY_OF_MONTH);
    }
    return dayOfMonth(advance());
  }

  private int parseDayOf(MonthName month) throws HronException {
    if (!at(TokenKind.NUMBER) && !at(TokenKind.ORDINAL_NUMBER)) {
      throw expected(Expected.DAY_NUMBER);
    }
    Token token = advance();
    int day = dayOfMonth(token);
    checkDayInMonth(day, token, month);
    return day;
  }

  private int dayOfMonth(Token token) throws HronException {
    int day = token.numberVal();
    if (day < 1 || day > 31) {
      throw error("day must be 1-31, got " + text(token), token);
    }
    return day;
  }

  private void checkDayInMonth(int day, Token token, MonthName month) throws HronException {
    int max = MAX_DAYS[month.number()];
    if (day > max) {
      throw error("day must be 1-" + max + " for " + month + ", got " + text(token), token);
    }
  }

  private ScheduleExpr parseYearRepeat(int interval) throws HronException {
    expect(TokenKind.ON, Expected.ON);

    YearTarget target;
    if (eat(TokenKind.THE)) {
      target = parseYearTargetAfterThe();
    } else if (at(TokenKind.MONTH_NAME)) {
      MonthName month = advance().monthNameVal();
      target = YearTarget.date(month, parseDayOf(month));
    } else {
      throw expected(Expected.YEAR_TARGET);
    }

    expect(TokenKind.AT, Expected.AT);
    return new YearRepeat(interval, target, parseTimeList());
  }

  private YearTarget parseYearTargetAfterThe() throws HronException {
    if (eat(TokenKind.LAST)) {
      if (eat(TokenKind.WEEKDAY)) {
        expect(TokenKind.OF, Expected.OF);
        return YearTarget.lastWeekday(parseMonthName());
      }
      if (at(TokenKind.DAY_NAME)) {
        Weekday weekday = advance().dayNameVal();
        expect(TokenKind.OF, Expected.OF);
        return YearTarget.ordinalWeekday(OrdinalPosition.LAST, weekday, parseMonthName());
      }
      throw expected(Expected.YEAR_LAST);
    }
    if (at(TokenKind.ORDINAL)) {
      OrdinalPosition ordinal = advance().ordinalVal();
      Weekday weekday = parseDayName();
      expect(TokenKind.OF, Expected.OF);
      return YearTarget.ordinalWeekday(ordinal, weekday, parseMonthName());
    }
    if (at(TokenKind.ORDINAL_NUMBER)) {
      int day = parseOrdinalDay();
      Token dayToken = previous();
      expect(TokenKind.OF, Expected.OF);
      MonthName month = parseMonthName();
      checkDayInMonth(day, dayToken, month);
      return YearTarget.dayOfMonth(day, month);
    }
    throw expected(Expected.YEAR_THE);
  }

  private MonthName parseMonthName() throws HronException {
    if (!at(TokenKind.MONTH_NAME)) {
      throw expected(Expected.MONTH_NAME);
    }
    return advance().monthNameVal();
  }

  private List<MonthName> parseMonthList() throws HronException {
    List<MonthName> months = new ArrayList<>();
    do {
      months.add(parseMonthName());
    } while (eat(TokenKind.COMMA));
    return months;
  }

  private ScheduleExpr parseOn() throws HronException {
    DateSpec date = parseDate();
    expect(TokenKind.AT, Expected.AT);
    return new SingleDate(date, parseTimeList());
  }

  private DayFilter parseDayTarget() throws HronException {
    if (eat(TokenKind.DAY)) {
      return DayFilter.every();
    }
    if (eat(TokenKind.WEEKDAY)) {
      return DayFilter.weekday();
    }
    if (eat(TokenKind.WEEKEND)) {
      return DayFilter.weekend();
    }
    if (at(TokenKind.DAY_NAME)) {
      return DayFilter.days(parseDayList());
    }
    throw expected(Expected.DAY_TARGET);
  }

  private Weekday parseDayName() throws HronException {
    if (!at(TokenKind.DAY_NAME)) {
      throw expected(Expected.DAY_NAME);
    }
    return advance().dayNameVal();
  }

  private List<Weekday> parseDayList() throws HronException {
    List<Weekday> days = new ArrayList<>();
    do {
      days.add(parseDayName());
    } while (eat(TokenKind.COMMA));
    return days;
  }

  private List<TimeOfDay> parseTimeList() throws HronException {
    List<TimeOfDay> times = new ArrayList<>();
    do {
      times.add(parseTime());
    } while (eat(TokenKind.COMMA));
    return times;
  }

  private TimeOfDay parseTime() throws HronException {
    if (!at(TokenKind.TIME)) {
      throw expected(Expected.TIME);
    }
    Token token = advance();
    return new TimeOfDay(token.timeHour(), token.timeMinute());
  }
}
