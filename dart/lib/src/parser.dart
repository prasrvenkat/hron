import 'ast.dart';
import 'error.dart';
import 'lexer.dart';

class _Parser {
  final List<Token> tokens;
  final String input;
  int pos = 0;

  _Parser(this.tokens, this.input);

  Token? peek() => pos < tokens.length ? tokens[pos] : null;

  TokenKind? peekKind() => peek()?.kind;

  Token? advance() {
    if (pos < tokens.length) {
      return tokens[pos++];
    }
    return null;
  }

  Span currentSpan() {
    final tok = peek();
    if (tok != null) return tok.span;
    if (tokens.isNotEmpty) {
      final last = tokens.last;
      return Span(last.span.end, last.span.end);
    }
    return const Span(0, 0);
  }

  HronError error(String message, Span span) =>
      HronError.parse(message, span, input);

  HronError errorAtEnd(String message) {
    final span = tokens.isNotEmpty
        ? Span(tokens.last.span.end, tokens.last.span.end)
        : const Span(0, 0);
    return HronError.parse(message, span, input);
  }

  Token consumeKind(String expected, bool Function(TokenKind) check) {
    final span = currentSpan();
    final tok = peek();
    if (tok != null && check(tok.kind)) {
      pos++;
      return tok;
    }
    if (tok != null) {
      throw error('expected $expected, got ${tokenKindType(tok.kind)}', span);
    }
    throw errorAtEnd('expected $expected');
  }

  // --- Grammar productions ---

  ScheduleData parseExpression() {
    final span = currentSpan();
    final kind = peekKind();

    ScheduleExpr expr;
    if (kind is EveryToken) {
      advance();
      expr = _parseEvery();
    } else if (kind is OnToken) {
      advance();
      expr = _parseOn();
    } else if (kind is OrdinalToken || kind is LastToken) {
      expr = _parseOrdinalRepeat();
    } else {
      throw error(
        "expected 'every', 'on', or an ordinal (first, second, ...)",
        span,
      );
    }

    return _parseTrailingClauses(expr);
  }

  ScheduleData _parseTrailingClauses(ScheduleExpr expr) {
    final schedule = ScheduleData(expr);

    // except
    if (peekKind() is ExceptToken) {
      advance();
      schedule.except = _parseExceptionList();
    }

    // until
    if (peekKind() is UntilToken) {
      advance();
      schedule.until = _parseUntilSpec();
    }

    // starting
    if (peekKind() is StartingToken) {
      advance();
      final k = peekKind();
      if (k is IsoDateToken) {
        _validateIsoDate(k.date);
        schedule.anchor = k.date;
        advance();
      } else {
        throw error(
          "expected ISO date (YYYY-MM-DD) after 'starting'",
          currentSpan(),
        );
      }
    }

    // during
    if (peekKind() is DuringToken) {
      advance();
      schedule.during = _parseMonthList();
    }

    // in <timezone>
    if (peekKind() is InToken) {
      advance();
      final k = peekKind();
      if (k is TimezoneToken) {
        schedule.timezone = k.tz;
        advance();
      } else {
        throw error("expected timezone after 'in'", currentSpan());
      }
    }

    return schedule;
  }

  List<ExceptionSpec> _parseExceptionList() {
    final exceptions = <ExceptionSpec>[_parseException()];
    while (peekKind() is CommaToken) {
      advance();
      exceptions.add(_parseException());
    }
    return exceptions;
  }

  ExceptionSpec _parseException() {
    final k = peekKind();
    if (k is IsoDateToken) {
      _validateIsoDate(k.date);
      advance();
      return IsoException(k.date);
    }
    if (k is MonthNameToken) {
      advance();
      final day = _parseDayNumber(
        'expected day number after month name in exception',
      );
      return NamedException(k.name, day);
    }
    throw error('expected ISO date or month-day in exception', currentSpan());
  }

  UntilSpec _parseUntilSpec() {
    final k = peekKind();
    if (k is IsoDateToken) {
      _validateIsoDate(k.date);
      advance();
      return IsoUntil(k.date);
    }
    if (k is MonthNameToken) {
      advance();
      final day = _parseDayNumber(
        'expected day number after month name in until',
      );
      return NamedUntil(k.name, day);
    }
    throw error("expected ISO date or month-day after 'until'", currentSpan());
  }

  int _parseDayNumber(String errorMsg) {
    final k = peekKind();
    if (k is NumberToken) {
      advance();
      return k.value;
    }
    if (k is OrdinalNumberToken) {
      advance();
      return k.value;
    }
    throw error(errorMsg, currentSpan());
  }

  // After "every": dispatch
  ScheduleExpr _parseEvery() {
    if (peek() == null) throw errorAtEnd('expected repeater');

    final k = peekKind()!;

    if (k is YearToken) {
      advance();
      return _parseYearRepeat(1);
    }
    if (k is DayToken) {
      return _parseDayRepeat(1, EveryDay());
    }
    if (k is WeekdayKeyToken) {
      advance();
      return _parseDayRepeat(1, WeekdayFilter());
    }
    if (k is WeekendKeyToken) {
      advance();
      return _parseDayRepeat(1, WeekendFilter());
    }
    if (k is DayNameToken) {
      final days = _parseDayList();
      return _parseDayRepeat(1, SpecificDays(days));
    }
    if (k is MonthToken) {
      advance();
      return _parseMonthRepeat(1);
    }
    if (k is NumberToken) {
      return _parseNumberRepeat();
    }

    throw error(
      "expected day, weekday, weekend, year, day name, month, or number after 'every'",
      currentSpan(),
    );
  }

  ScheduleExpr _parseDayRepeat(int interval, DayFilter days) {
    if (days is EveryDay) {
      consumeKind("'day'", (k) => k is DayToken);
    }
    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();
    return DayRepeat(interval, days, times);
  }

  ScheduleExpr _parseNumberRepeat() {
    final k = peekKind()! as NumberToken;
    final num = k.value;
    final numSpan = currentSpan();
    advance();

    if (num == 0) {
      throw error('interval must be at least 1', numSpan);
    }

    final next = peekKind();
    if (next is WeeksToken) {
      advance();
      return _parseWeekRepeat(num);
    }
    if (next is IntervalUnitToken) {
      return _parseIntervalRepeat(num);
    }
    if (next is DayToken) {
      return _parseDayRepeat(num, EveryDay());
    }
    if (next is MonthToken) {
      advance();
      return _parseMonthRepeat(num);
    }
    if (next is YearToken) {
      advance();
      return _parseYearRepeat(num);
    }

    throw error(
      "expected 'weeks', 'days', 'months', 'years', 'min', 'minutes', 'hour', or 'hours' after number",
      currentSpan(),
    );
  }

  ScheduleExpr _parseIntervalRepeat(int interval) {
    final k = peekKind()! as IntervalUnitToken;
    advance();

    final unit = k.unit;

    consumeKind("'from'", (k) => k is FromToken);
    final from = _parseTime();
    consumeKind("'to'", (k) => k is ToToken);
    final to = _parseTime();

    DayFilter? dayFilter;
    if (peekKind() is OnToken) {
      advance();
      dayFilter = _parseDayTarget();
    }

    return IntervalRepeat(interval, unit, from, to, dayFilter);
  }

  ScheduleExpr _parseWeekRepeat(int interval) {
    consumeKind("'on'", (k) => k is OnToken);
    final days = _parseDayList();
    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();
    return WeekRepeat(interval, days, times);
  }

  ScheduleExpr _parseMonthRepeat(int interval) {
    consumeKind("'on'", (k) => k is OnToken);
    consumeKind("'the'", (k) => k is TheToken);

    MonthTarget target;
    final k = peekKind();

    if (k is LastToken) {
      advance();
      final next = peekKind();
      if (next is DayToken) {
        advance();
        target = LastDayTarget();
      } else if (next is WeekdayKeyToken) {
        advance();
        target = LastWeekdayTarget();
      } else {
        throw error("expected 'day' or 'weekday' after 'last'", currentSpan());
      }
    } else if (k is OrdinalNumberToken) {
      final specs = _parseOrdinalDayList();
      target = DaysTarget(specs);
    } else if (k is NextToken || k is PreviousToken || k is NearestToken) {
      target = _parseNearestWeekdayTarget();
    } else {
      throw error(
        "expected ordinal day (1st, 15th), 'last', or '[next|previous] nearest' after 'the'",
        currentSpan(),
      );
    }

    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();
    return MonthRepeat(interval, target, times);
  }

  /// Parse [next|previous] nearest weekday to `<day>`
  MonthTarget _parseNearestWeekdayTarget() {
    // Optional direction: "next" or "previous"
    NearestDirection? direction;
    final k = peekKind();
    if (k is NextToken) {
      advance();
      direction = NearestDirection.next;
    } else if (k is PreviousToken) {
      advance();
      direction = NearestDirection.previous;
    }

    consumeKind("'nearest'", (k) => k is NearestToken);
    consumeKind("'weekday'", (k) => k is WeekdayKeyToken);
    consumeKind("'to'", (k) => k is ToToken);

    final day = _parseOrdinalDayNumber();
    return NearestWeekdayTarget(day, direction);
  }

  int _parseOrdinalDayNumber() {
    final k = peekKind();
    if (k is OrdinalNumberToken) {
      advance();
      return k.value;
    }
    throw error('expected ordinal day number', currentSpan());
  }

  ScheduleExpr _parseOrdinalRepeat() {
    final ordinal = _parseOrdinalPosition();

    final k = peekKind();
    if (k is! DayNameToken) {
      throw error('expected day name after ordinal', currentSpan());
    }
    final day = k.name;
    advance();

    consumeKind("'of'", (k) => k is OfToken);
    consumeKind("'every'", (k) => k is EveryToken);

    // Optional interval: "of every 2 months" vs "of every month"
    int interval = 1;
    final next = peekKind();
    if (next is NumberToken) {
      interval = next.value;
      final intervalSpan = currentSpan();
      advance();
      if (interval == 0) {
        throw error('interval must be at least 1', intervalSpan);
      }
    }

    consumeKind("'month'", (k) => k is MonthToken);
    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();

    return OrdinalRepeat(interval, ordinal, day, times);
  }

  ScheduleExpr _parseYearRepeat(int interval) {
    consumeKind("'on'", (k) => k is OnToken);

    YearTarget target;
    final k = peekKind();

    if (k is TheToken) {
      advance();
      target = _parseYearTargetAfterThe();
    } else if (k is MonthNameToken) {
      final month = k.name;
      advance();
      final day = _parseDayNumber('expected day number after month name');
      target = DateTarget(month, day);
    } else {
      throw error(
        "expected month name or 'the' after 'every year on'",
        currentSpan(),
      );
    }

    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();
    return YearRepeat(interval, target, times);
  }

  YearTarget _parseYearTargetAfterThe() {
    final k = peekKind();

    if (k is LastToken) {
      advance();
      final next = peekKind();
      if (next is WeekdayKeyToken) {
        advance();
        consumeKind("'of'", (k) => k is OfToken);
        final month = _parseMonthNameToken();
        return LastWeekdayYearTarget(month);
      }
      if (next is DayNameToken) {
        final weekday = next.name;
        advance();
        consumeKind("'of'", (k) => k is OfToken);
        final month = _parseMonthNameToken();
        return OrdinalWeekdayTarget(OrdinalPosition.last, weekday, month);
      }
      throw error(
        "expected 'weekday' or day name after 'last' in yearly expression",
        currentSpan(),
      );
    }

    if (k is OrdinalToken) {
      final ordinal = _parseOrdinalPosition();
      final next = peekKind();
      if (next is DayNameToken) {
        final weekday = next.name;
        advance();
        consumeKind("'of'", (k) => k is OfToken);
        final month = _parseMonthNameToken();
        return OrdinalWeekdayTarget(ordinal, weekday, month);
      }
      throw error(
        'expected day name after ordinal in yearly expression',
        currentSpan(),
      );
    }

    if (k is OrdinalNumberToken) {
      final day = k.value;
      advance();
      consumeKind("'of'", (k) => k is OfToken);
      final month = _parseMonthNameToken();
      return DayOfMonthTarget(day, month);
    }

    throw error(
      "expected ordinal, day number, or 'last' after 'the' in yearly expression",
      currentSpan(),
    );
  }

  MonthName _parseMonthNameToken() {
    final k = peekKind();
    if (k is MonthNameToken) {
      advance();
      return k.name;
    }
    throw error('expected month name', currentSpan());
  }

  OrdinalPosition _parseOrdinalPosition() {
    final span = currentSpan();
    final k = peekKind();

    if (k is OrdinalToken) {
      advance();
      return k.name;
    }
    if (k is LastToken) {
      advance();
      return OrdinalPosition.last;
    }
    throw error(
      'expected ordinal (first, second, third, fourth, fifth, last)',
      span,
    );
  }

  ScheduleExpr _parseOn() {
    final date = _parseDateTarget();
    consumeKind("'at'", (k) => k is AtToken);
    final times = _parseTimeList();
    return SingleDate(date, times);
  }

  void _validateIsoDate(String dateStr) {
    final parsed = DateTime.tryParse(dateStr);
    if (parsed == null) {
      throw error('invalid date: $dateStr', currentSpan());
    }
    // DateTime.tryParse silently rolls invalid dates (e.g. Feb 30 -> Mar 2)
    // Verify the day component matches the input
    final parts = dateStr.split('-');
    final inputDay = int.parse(parts[2]);
    final inputMonth = int.parse(parts[1]);
    if (parsed.day != inputDay || parsed.month != inputMonth) {
      throw error('invalid date: $dateStr', currentSpan());
    }
  }

  DateSpec _parseDateTarget() {
    final k = peekKind();

    if (k is IsoDateToken) {
      _validateIsoDate(k.date);
      advance();
      return IsoDate(k.date);
    }
    if (k is MonthNameToken) {
      final month = k.name;
      advance();
      final day = _parseDayNumber('expected day number after month name');
      return NamedDate(month, day);
    }
    throw error('expected date (ISO date or month name)', currentSpan());
  }

  DayFilter _parseDayTarget() {
    final k = peekKind();
    if (k is DayToken) {
      advance();
      return EveryDay();
    }
    if (k is WeekdayKeyToken) {
      advance();
      return WeekdayFilter();
    }
    if (k is WeekendKeyToken) {
      advance();
      return WeekendFilter();
    }
    if (k is DayNameToken) {
      final days = _parseDayList();
      return SpecificDays(days);
    }
    throw error(
      "expected 'day', 'weekday', 'weekend', or day name",
      currentSpan(),
    );
  }

  List<Weekday> _parseDayList() {
    final k = peekKind();
    if (k is! DayNameToken) {
      throw error('expected day name', currentSpan());
    }
    final days = <Weekday>[k.name];
    advance();

    while (peekKind() is CommaToken) {
      advance();
      final next = peekKind();
      if (next is! DayNameToken) {
        throw error("expected day name after ','", currentSpan());
      }
      days.add(next.name);
      advance();
    }
    return days;
  }

  List<DayOfMonthSpec> _parseOrdinalDayList() {
    final specs = <DayOfMonthSpec>[_parseOrdinalDaySpec()];
    while (peekKind() is CommaToken) {
      advance();
      specs.add(_parseOrdinalDaySpec());
    }
    return specs;
  }

  DayOfMonthSpec _parseOrdinalDaySpec() {
    final k = peekKind();
    if (k is! OrdinalNumberToken) {
      throw error('expected ordinal day number', currentSpan());
    }
    final start = k.value;
    advance();

    if (peekKind() is ToToken) {
      advance();
      final next = peekKind();
      if (next is! OrdinalNumberToken) {
        throw error("expected ordinal day number after 'to'", currentSpan());
      }
      final end = next.value;
      advance();
      return DayRange(start, end);
    }

    return SingleDay(start);
  }

  List<MonthName> _parseMonthList() {
    final months = <MonthName>[_parseMonthNameToken()];
    while (peekKind() is CommaToken) {
      advance();
      months.add(_parseMonthNameToken());
    }
    return months;
  }

  List<TimeOfDay> _parseTimeList() {
    final times = <TimeOfDay>[_parseTime()];
    while (peekKind() is CommaToken) {
      advance();
      times.add(_parseTime());
    }
    return times;
  }

  TimeOfDay _parseTime() {
    final span = currentSpan();
    final k = peekKind();
    if (k is TimeToken) {
      advance();
      return TimeOfDay(k.hour, k.minute);
    }
    throw error('expected time (HH:MM)', span);
  }
}

ScheduleData parse(String input) {
  final tokens = tokenize(input);

  if (tokens.isEmpty) {
    throw HronError.parse('empty expression', const Span(0, 0), input);
  }

  final parser = _Parser(tokens, input);
  final schedule = parser.parseExpression();

  if (parser.peek() != null) {
    throw HronError.parse(
      'unexpected tokens after expression',
      parser.currentSpan(),
      input,
    );
  }

  return schedule;
}
