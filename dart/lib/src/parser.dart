import 'package:timezone/timezone.dart' show timeZoneDatabase;

import 'ast.dart';
import 'error.dart';
import 'lexer.dart';

/// The `{what}` of each `expected {what}, got ...` error, one per phrase in
/// the position table of spec/README.md, "Parse errors".
abstract final class _Expected {
  static const everyOrOn = "'every' or 'on'";
  static const repeater =
      "'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number";
  static const unit =
      "a unit ('min', 'hours', 'days', 'weeks', 'months' or 'years')";
  static const at = "'at'";
  static const time = 'a time (HH:MM)';
  static const from = "'from'";
  static const to = "'to'";
  static const dayTarget = "'day', 'weekday', 'weekend' or a day name";
  static const on = "'on'";
  static const dayName = 'a day name';
  static const the = "'the'";
  static const monthTarget =
      "a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'";
  static const monthLast = "'day', 'weekday' or a day name";
  static const nearest = "'nearest'";
  static const weekday = "'weekday'";
  static const dayOfMonth = 'a day such as 15th';
  static const yearTarget = "a month name or 'the'";
  static const yearThe =
      "a day such as 15th, 'last' or an ordinal such as 'first'";
  static const yearLast = "'weekday' or a day name";
  static const of = "'of'";
  static const monthName = 'a month name';
  static const dayNumber = 'a day number';
  static const date = 'a date (YYYY-MM-DD, or a month and day)';
  static const isoDate = 'a date (YYYY-MM-DD)';
  static const timezone = 'a timezone';
}

const _clauseOrder = ['except', 'until', 'starting', 'during', 'in'];

class _Parser {
  final List<Token> tokens;
  final String input;
  int pos = 0;
  int? untilStart;
  int? untilEnd;

  _Parser(this.tokens, this.input);

  Token? peek() => pos < tokens.length ? tokens[pos] : null;

  TokenKind? peekKind() => peek()?.kind;

  Token advance() => tokens[pos++];

  Token previous() => tokens[pos - 1];

  bool eat<T extends TokenKind>() {
    final found = peekKind() is T;
    if (found) pos++;
    return found;
  }

  void expect<T extends TokenKind>(String what) {
    if (!eat<T>()) throw expected(what);
  }

  String text(Token token) => input.substring(token.start, token.end);

  HronError error(String message, int start, int end) =>
      HronError.parse(message, codePointSpan(input, start, end), input);

  HronError expected(String what) {
    final token = peek();
    if (token != null) {
      return error(
        "expected $what, got '${text(token)}'",
        token.start,
        token.end,
      );
    }
    final end = tokens.last.end;
    return error('expected $what, got end of input', end, end);
  }

  ScheduleExpr parseExpression() {
    if (eat<EveryToken>()) return _parseEvery();
    if (eat<OnToken>()) return _parseOn();
    throw expected(_Expected.everyOrOn);
  }

  ScheduleData parseClauses(ScheduleExpr expr) {
    final except = eat<ExceptToken>()
        ? _parseExceptionList()
        : const <ExceptionSpec>[];

    UntilSpec? until;
    if (peekKind() is UntilToken) {
      final untilToken = advance();
      until = switch (_parseDate()) {
        IsoDate(:final date) => IsoUntil(date),
        NamedDate(:final month, :final day) => NamedUntil(month, day),
      };
      untilStart = untilToken.start;
      untilEnd = previous().end;
    }

    String? starting;
    if (eat<StartingToken>()) {
      final kind = peekKind();
      if (kind is! IsoDateToken) throw expected(_Expected.isoDate);
      _checkIsoDate(advance());
      starting = kind.date;
    }

    final during = eat<DuringToken>() ? _parseMonthList() : const <MonthName>[];

    String? timezone;
    if (eat<InToken>()) {
      if (peekKind() is! TimezoneToken) throw expected(_Expected.timezone);
      timezone = _canonicalTimezone(advance());
    }

    return ScheduleData(
      expr,
      except: except,
      until: until,
      starting: starting,
      during: during,
      timezone: timezone,
    );
  }

  HronError leftover(ScheduleData schedule) {
    final token = tokens[pos];
    // Every clause holds at least one item, so a clause was read exactly when its field is set.
    final read = [
      schedule.except.isNotEmpty,
      schedule.until != null,
      schedule.starting != null,
      schedule.during.isNotEmpty,
      schedule.timezone != null,
    ];
    final clause = switch (token.kind) {
      ExceptToken() => 0,
      UntilToken() => 1,
      StartingToken() => 2,
      DuringToken() => 3,
      InToken() => 4,
      _ => null,
    };
    final lastRead = read.lastIndexOf(true);
    final String message;
    if (clause != null && read[clause]) {
      message = "duplicate '${_clauseOrder[clause]}' clause";
    } else if (clause != null && lastRead >= 0) {
      message =
          "'${_clauseOrder[clause]}' must come before '${_clauseOrder[lastRead]}'";
    } else {
      message = "unexpected '${text(token)}' after the schedule";
    }
    return error(message, token.start, token.end);
  }

  void checkNamedUntil(ScheduleData schedule) {
    if (schedule.until case NamedUntil(
      :final month,
      :final day,
    ) when schedule.starting == null) {
      throw HronError.parse(
        'until ${month.name} $day has no year: add a starting date, or use an ISO date',
        codePointSpan(input, untilStart!, untilEnd!),
        input,
        suggestion: 'until ${month.name} $day starting YYYY-MM-DD',
      );
    }
  }

  List<ExceptionSpec> _parseExceptionList() {
    final exceptions = [_parseException()];
    while (eat<CommaToken>()) {
      exceptions.add(_parseException());
    }
    return List.unmodifiable(exceptions);
  }

  ExceptionSpec _parseException() => switch (_parseDate()) {
    IsoDate(:final date) => IsoException(date),
    NamedDate(:final month, :final day) => NamedException(month, day),
  };

  DateSpec _parseDate() {
    switch (peekKind()) {
      case IsoDateToken(:final date):
        _checkIsoDate(advance());
        return IsoDate(date);
      case MonthNameToken(:final name):
        advance();
        return NamedDate(name, _parseDayOf(name));
      default:
        throw expected(_Expected.date);
    }
  }

  void _checkIsoDate(Token token) {
    final date = text(token);
    final year = int.parse(date.substring(0, 4));
    final month = int.parse(date.substring(5, 7));
    final day = int.parse(date.substring(8, 10));
    final calendar =
        year >= 1 &&
        month >= 1 &&
        month <= 12 &&
        day >= 1 &&
        day <= _daysInMonth(year, month);
    if (!calendar) {
      throw error(
        'date must be a calendar date from 0001-01-01 to 9999-12-31, got $date',
        token.start,
        token.end,
      );
    }
  }

  /// The IANA capitalization of the name, from the loaded timezone database
  /// (spec/README.md, "Parse-time validation"). Links keep their own name.
  String _canonicalTimezone(Token token) {
    final name = text(token);
    final lower = asciiLower(name);
    if (lower == 'utc') return 'UTC';
    if (!timeZoneDatabase.isInitialized && name.contains('/')) {
      throw error(
        "timezone '$name' needs timezone data: call initializeTimeZones() "
        'from package:timezone/data/latest_all.dart before parsing',
        token.start,
        token.end,
      );
    }
    final isAscii = name.codeUnits.every((c) => c < 128);
    final legacy = ['systemv/', 'posix/', 'right/'].any(lower.startsWith);
    final match = isAscii && !legacy && name.contains('/')
        ? timeZoneDatabase.locations.keys
              .where((n) => asciiLower(n) == lower)
              .firstOrNull
        : null;
    if (match == null) {
      throw error(
        'timezone must be UTC or an Area/Location name such as America/New_York, got $name',
        token.start,
        token.end,
      );
    }
    return match;
  }

  ScheduleExpr _parseEvery() {
    switch (peekKind()) {
      case DayToken():
        advance();
        return _parseDayRepeat(1, EveryDay());
      case WeekdayKeyToken():
        advance();
        return _parseDayRepeat(1, WeekdayFilter());
      case WeekendKeyToken():
        advance();
        return _parseDayRepeat(1, WeekendFilter());
      case DayNameToken():
        return _parseDayRepeat(1, SpecificDays(_parseDayList()));
      case WeeksToken():
        advance();
        return _parseWeekRepeat(1);
      case MonthToken():
        advance();
        return _parseMonthRepeat(1);
      case YearToken():
        advance();
        return _parseYearRepeat(1);
      case NumberToken(:final value):
        return _parseNumberRepeat(value);
      default:
        throw expected(_Expected.repeater);
    }
  }

  ScheduleExpr _parseDayRepeat(int interval, DayFilter days) {
    expect<AtToken>(_Expected.at);
    return DayRepeat(interval, days, _parseTimeList());
  }

  ScheduleExpr _parseNumberRepeat(int interval) {
    final number = advance();
    if (interval == 0) {
      throw error(
        'interval must be 1-2147483647, got ${text(number)}',
        number.start,
        number.end,
      );
    }

    switch (peekKind()) {
      case WeeksToken():
        advance();
        return _parseWeekRepeat(interval);
      case IntervalUnitToken(:final unit):
        advance();
        return _parseIntervalRepeat(interval, unit);
      case DayToken():
        advance();
        return _parseDayRepeat(interval, EveryDay());
      case MonthToken():
        advance();
        return _parseMonthRepeat(interval);
      case YearToken():
        advance();
        return _parseYearRepeat(interval);
      default:
        throw expected(_Expected.unit);
    }
  }

  ScheduleExpr _parseIntervalRepeat(int interval, IntervalUnit unit) {
    expect<FromToken>(_Expected.from);
    final from = _parseTime();
    final fromToken = previous();
    expect<ToToken>(_Expected.to);
    final to = _parseTime();
    final toToken = previous();
    if (from.hour * 60 + from.minute > to.hour * 60 + to.minute) {
      throw error(
        'time window must not run backwards: ${text(fromToken)} to '
        '${text(toToken)} (a window cannot cross midnight)',
        fromToken.start,
        toToken.end,
      );
    }

    final dayFilter = eat<OnToken>() ? _parseDayTarget() : null;
    return IntervalRepeat(interval, unit, from, to, dayFilter);
  }

  ScheduleExpr _parseWeekRepeat(int interval) {
    expect<OnToken>(_Expected.on);
    final days = _parseDayList();
    expect<AtToken>(_Expected.at);
    return WeekRepeat(interval, days, _parseTimeList());
  }

  ScheduleExpr _parseMonthRepeat(int interval) {
    expect<OnToken>(_Expected.on);
    expect<TheToken>(_Expected.the);

    final MonthTarget target;
    switch (peekKind()) {
      case LastToken():
        advance();
        target = switch (peekKind()) {
          DayToken() => LastDayTarget(),
          WeekdayKeyToken() => LastWeekdayTarget(),
          DayNameToken(:final name) => OrdinalWeekdayMonthTarget(
            OrdinalPosition.last,
            name,
          ),
          _ => throw expected(_Expected.monthLast),
        };
        advance();
      case OrdinalToken(:final name):
        advance();
        target = OrdinalWeekdayMonthTarget(name, _parseDayName());
      case OrdinalNumberToken():
        target = DaysTarget(_parseOrdinalDayList());
      case NextToken() || PreviousToken() || NearestToken():
        target = _parseNearestWeekdayTarget();
      default:
        throw expected(_Expected.monthTarget);
    }

    expect<AtToken>(_Expected.at);
    return MonthRepeat(interval, target, _parseTimeList());
  }

  MonthTarget _parseNearestWeekdayTarget() {
    final direction = eat<NextToken>()
        ? NearestDirection.next
        : eat<PreviousToken>()
        ? NearestDirection.previous
        : null;
    expect<NearestToken>(_Expected.nearest);
    expect<WeekdayKeyToken>(_Expected.weekday);
    expect<ToToken>(_Expected.to);
    final (day, _) = _parseOrdinalDay();
    return NearestWeekdayTarget(day, direction);
  }

  List<DayOfMonthSpec> _parseOrdinalDayList() {
    final specs = [_parseOrdinalDaySpec()];
    while (eat<CommaToken>()) {
      specs.add(_parseOrdinalDaySpec());
    }
    return List.unmodifiable(specs);
  }

  DayOfMonthSpec _parseOrdinalDaySpec() {
    final (start, startToken) = _parseOrdinalDay();
    if (!eat<ToToken>()) return SingleDay(start);
    final (end, endToken) = _parseOrdinalDay();
    if (start > end) {
      throw error(
        'day range must not run backwards: ${text(startToken)} to ${text(endToken)}',
        startToken.start,
        endToken.end,
      );
    }
    return DayRange(start, end);
  }

  (int, Token) _parseOrdinalDay() {
    final kind = peekKind();
    if (kind is! OrdinalNumberToken) throw expected(_Expected.dayOfMonth);
    final token = advance();
    return (_dayOfMonth(kind.value, token), token);
  }

  int _parseDayOf(MonthName month) {
    final n = switch (peekKind()) {
      NumberToken(:final value) || OrdinalNumberToken(:final value) => value,
      _ => throw expected(_Expected.dayNumber),
    };
    final token = advance();
    final day = _dayOfMonth(n, token);
    _checkDayInMonth(day, token, month);
    return day;
  }

  int _dayOfMonth(int n, Token token) {
    if (n < 1 || n > 31) {
      throw error(
        'day must be 1-31, got ${text(token)}',
        token.start,
        token.end,
      );
    }
    return n;
  }

  void _checkDayInMonth(int day, Token token, MonthName month) {
    final max = switch (month) {
      MonthName.feb => 29,
      MonthName.apr || MonthName.jun || MonthName.sep || MonthName.nov => 30,
      _ => 31,
    };
    if (day > max) {
      throw error(
        'day must be 1-$max for ${month.name}, got ${text(token)}',
        token.start,
        token.end,
      );
    }
  }

  ScheduleExpr _parseYearRepeat(int interval) {
    expect<OnToken>(_Expected.on);

    final YearTarget target;
    switch (peekKind()) {
      case TheToken():
        advance();
        target = _parseYearTargetAfterThe();
      case MonthNameToken(:final name):
        advance();
        target = DateTarget(name, _parseDayOf(name));
      default:
        throw expected(_Expected.yearTarget);
    }

    expect<AtToken>(_Expected.at);
    return YearRepeat(interval, target, _parseTimeList());
  }

  YearTarget _parseYearTargetAfterThe() {
    switch (peekKind()) {
      case LastToken():
        advance();
        switch (peekKind()) {
          case WeekdayKeyToken():
            advance();
            expect<OfToken>(_Expected.of);
            return LastWeekdayYearTarget(_parseMonthName());
          case DayNameToken(:final name):
            advance();
            expect<OfToken>(_Expected.of);
            return OrdinalWeekdayTarget(
              OrdinalPosition.last,
              name,
              _parseMonthName(),
            );
          default:
            throw expected(_Expected.yearLast);
        }
      case OrdinalToken(:final name):
        advance();
        final weekday = _parseDayName();
        expect<OfToken>(_Expected.of);
        return OrdinalWeekdayTarget(name, weekday, _parseMonthName());
      case OrdinalNumberToken():
        final (day, dayToken) = _parseOrdinalDay();
        expect<OfToken>(_Expected.of);
        final month = _parseMonthName();
        _checkDayInMonth(day, dayToken, month);
        return DayOfMonthTarget(day, month);
      default:
        throw expected(_Expected.yearThe);
    }
  }

  MonthName _parseMonthName() {
    final kind = peekKind();
    if (kind is! MonthNameToken) throw expected(_Expected.monthName);
    advance();
    return kind.name;
  }

  List<MonthName> _parseMonthList() {
    final months = [_parseMonthName()];
    while (eat<CommaToken>()) {
      months.add(_parseMonthName());
    }
    return List.unmodifiable(months);
  }

  ScheduleExpr _parseOn() {
    final date = _parseDate();
    expect<AtToken>(_Expected.at);
    return SingleDate(date, _parseTimeList());
  }

  DayFilter _parseDayTarget() {
    switch (peekKind()) {
      case DayToken():
        advance();
        return EveryDay();
      case WeekdayKeyToken():
        advance();
        return WeekdayFilter();
      case WeekendKeyToken():
        advance();
        return WeekendFilter();
      case DayNameToken():
        return SpecificDays(_parseDayList());
      default:
        throw expected(_Expected.dayTarget);
    }
  }

  Weekday _parseDayName() {
    final kind = peekKind();
    if (kind is! DayNameToken) throw expected(_Expected.dayName);
    advance();
    return kind.name;
  }

  List<Weekday> _parseDayList() {
    final days = [_parseDayName()];
    while (eat<CommaToken>()) {
      days.add(_parseDayName());
    }
    return List.unmodifiable(days);
  }

  List<TimeOfDay> _parseTimeList() {
    final times = [_parseTime()];
    while (eat<CommaToken>()) {
      times.add(_parseTime());
    }
    return List.unmodifiable(times);
  }

  TimeOfDay _parseTime() {
    final kind = peekKind();
    if (kind is! TimeToken) throw expected(_Expected.time);
    advance();
    return TimeOfDay(kind.hour, kind.minute);
  }
}

int _daysInMonth(int year, int month) {
  if (month == 2) {
    final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    return leap ? 29 : 28;
  }
  return const {4, 6, 9, 11}.contains(month) ? 30 : 31;
}

ScheduleData parse(String input) {
  final tokens = tokenize(input);
  if (tokens.isEmpty) {
    throw HronError.parse('empty expression', const Span(0, 0), input);
  }

  final parser = _Parser(tokens, input);
  final expr = parser.parseExpression();
  final schedule = parser.parseClauses(expr);
  if (parser.peek() != null) throw parser.leftover(schedule);
  // spec/README.md, "Parse errors": every other error wins over a named until without starting.
  parser.checkNamedUntil(schedule);
  return schedule;
}
