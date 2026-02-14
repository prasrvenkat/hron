import 'ast.dart';
import 'error.dart';

// --- Token kinds ---

sealed class TokenKind {}

class EveryToken extends TokenKind {}

class OnToken extends TokenKind {}

class AtToken extends TokenKind {}

class FromToken extends TokenKind {}

class ToToken extends TokenKind {}

class InToken extends TokenKind {}

class OfToken extends TokenKind {}

class TheToken extends TokenKind {}

class LastToken extends TokenKind {}

class ExceptToken extends TokenKind {}

class UntilToken extends TokenKind {}

class StartingToken extends TokenKind {}

class DuringToken extends TokenKind {}

class NearestToken extends TokenKind {}

class NextToken extends TokenKind {}

class PreviousToken extends TokenKind {}

class YearToken extends TokenKind {}

class DayToken extends TokenKind {}

class WeekdayKeyToken extends TokenKind {}

class WeekendKeyToken extends TokenKind {}

class WeeksToken extends TokenKind {}

class MonthToken extends TokenKind {}

class CommaToken extends TokenKind {}

class DayNameToken extends TokenKind {
  final Weekday name;
  DayNameToken(this.name);
}

class MonthNameToken extends TokenKind {
  final MonthName name;
  MonthNameToken(this.name);
}

class OrdinalToken extends TokenKind {
  final OrdinalPosition name;
  OrdinalToken(this.name);
}

class IntervalUnitToken extends TokenKind {
  final IntervalUnit unit;
  IntervalUnitToken(this.unit);
}

class NumberToken extends TokenKind {
  final int value;
  NumberToken(this.value);
}

class OrdinalNumberToken extends TokenKind {
  final int value;
  OrdinalNumberToken(this.value);
}

class TimeToken extends TokenKind {
  final int hour;
  final int minute;
  TimeToken(this.hour, this.minute);
}

class IsoDateToken extends TokenKind {
  final String date;
  IsoDateToken(this.date);
}

class TimezoneToken extends TokenKind {
  final String tz;
  TimezoneToken(this.tz);
}

// --- Token ---

class Token {
  final TokenKind kind;
  final Span span;
  Token(this.kind, this.span);
}

// --- Tokenizer ---

List<Token> tokenize(String input) => _Lexer(input).tokenize();

class _Lexer {
  final String input;
  int pos = 0;
  bool afterIn = false;

  _Lexer(this.input);

  List<Token> tokenize() {
    final tokens = <Token>[];
    while (true) {
      _skipWhitespace();
      if (pos >= input.length) break;

      if (afterIn) {
        afterIn = false;
        tokens.add(_lexTimezone());
        continue;
      }

      final start = pos;
      final ch = input[pos];

      if (ch == ',') {
        pos++;
        tokens.add(Token(CommaToken(), Span(start, pos)));
        continue;
      }

      if (_isDigit(ch)) {
        tokens.add(_lexNumberOrTimeOrDate());
        continue;
      }

      if (_isAlpha(ch)) {
        tokens.add(_lexWord());
        continue;
      }

      throw HronError.lex(
        "unexpected character '$ch'",
        Span(start, start + 1),
        input,
      );
    }
    return tokens;
  }

  void _skipWhitespace() {
    while (pos < input.length && _isWhitespace(input[pos])) {
      pos++;
    }
  }

  Token _lexTimezone() {
    _skipWhitespace();
    final start = pos;
    while (pos < input.length && !_isWhitespace(input[pos])) {
      pos++;
    }
    final tz = input.substring(start, pos);
    if (tz.isEmpty) {
      throw HronError.lex(
        "expected timezone after 'in'",
        Span(start, start + 1),
        input,
      );
    }
    return Token(TimezoneToken(tz), Span(start, pos));
  }

  Token _lexNumberOrTimeOrDate() {
    final start = pos;
    final numStart = pos;
    while (pos < input.length && _isDigit(input[pos])) {
      pos++;
    }
    final digits = input.substring(numStart, pos);

    // ISO date: YYYY-MM-DD
    if (digits.length == 4 && pos < input.length && input[pos] == '-') {
      final remaining = input.substring(start);
      if (remaining.length >= 10 &&
          remaining[4] == '-' &&
          _isDigit(remaining[5]) &&
          _isDigit(remaining[6]) &&
          remaining[7] == '-' &&
          _isDigit(remaining[8]) &&
          _isDigit(remaining[9])) {
        pos = start + 10;
        return Token(
          IsoDateToken(input.substring(start, pos)),
          Span(start, pos),
        );
      }
    }

    // Time: HH:MM
    if ((digits.length == 1 || digits.length == 2) &&
        pos < input.length &&
        input[pos] == ':') {
      pos++; // skip ':'
      final minStart = pos;
      while (pos < input.length && _isDigit(input[pos])) {
        pos++;
      }
      final minDigits = input.substring(minStart, pos);
      if (minDigits.length == 2) {
        final hour = int.parse(digits);
        final minute = int.parse(minDigits);
        if (hour > 23 || minute > 59) {
          throw HronError.lex('invalid time', Span(start, pos), input);
        }
        return Token(TimeToken(hour, minute), Span(start, pos));
      }
    }

    final num = int.tryParse(digits);
    if (num == null) {
      throw HronError.lex('invalid number', Span(start, pos), input);
    }

    // Ordinal suffix: st, nd, rd, th
    if (pos + 1 < input.length) {
      final suffix = input.substring(pos, pos + 2).toLowerCase();
      if (suffix == 'st' ||
          suffix == 'nd' ||
          suffix == 'rd' ||
          suffix == 'th') {
        pos += 2;
        return Token(OrdinalNumberToken(num), Span(start, pos));
      }
    }

    return Token(NumberToken(num), Span(start, pos));
  }

  Token _lexWord() {
    final start = pos;
    while (pos < input.length &&
        (_isAlphanumeric(input[pos]) || input[pos] == '_')) {
      pos++;
    }
    final word = input.substring(start, pos).toLowerCase();
    final span = Span(start, pos);

    final kind = _keywordMap[word];
    if (kind == null) {
      throw HronError.lex("unknown keyword '$word'", span, input);
    }

    if (kind is InToken) {
      afterIn = true;
    }

    return Token(kind, span);
  }
}

String tokenKindType(TokenKind kind) => switch (kind) {
  EveryToken() => 'every',
  OnToken() => 'on',
  AtToken() => 'at',
  FromToken() => 'from',
  ToToken() => 'to',
  InToken() => 'in',
  OfToken() => 'of',
  TheToken() => 'the',
  LastToken() => 'last',
  ExceptToken() => 'except',
  UntilToken() => 'until',
  StartingToken() => 'starting',
  DuringToken() => 'during',
  NearestToken() => 'nearest',
  NextToken() => 'next',
  PreviousToken() => 'previous',
  YearToken() => 'year',
  DayToken() => 'day',
  WeekdayKeyToken() => 'weekday',
  WeekendKeyToken() => 'weekend',
  WeeksToken() => 'weeks',
  MonthToken() => 'month',
  CommaToken() => 'comma',
  DayNameToken() => 'dayName',
  MonthNameToken() => 'monthName',
  OrdinalToken() => 'ordinal',
  IntervalUnitToken() => 'intervalUnit',
  NumberToken() => 'number',
  OrdinalNumberToken() => 'ordinalNumber',
  TimeToken() => 'time',
  IsoDateToken() => 'isoDate',
  TimezoneToken() => 'timezone',
};

final _keywordMap = <String, TokenKind>{
  'every': EveryToken(),
  'on': OnToken(),
  'at': AtToken(),
  'from': FromToken(),
  'to': ToToken(),
  'in': InToken(),
  'of': OfToken(),
  'the': TheToken(),
  'last': LastToken(),
  'except': ExceptToken(),
  'until': UntilToken(),
  'starting': StartingToken(),
  'during': DuringToken(),
  'nearest': NearestToken(),
  'next': NextToken(),
  'previous': PreviousToken(),
  'year': YearToken(),
  'years': YearToken(),
  'day': DayToken(),
  'days': DayToken(),
  'weekday': WeekdayKeyToken(),
  'weekdays': WeekdayKeyToken(),
  'weekend': WeekendKeyToken(),
  'weekends': WeekendKeyToken(),
  'weeks': WeeksToken(),
  'week': WeeksToken(),
  'month': MonthToken(),
  'months': MonthToken(),
  'monday': DayNameToken(Weekday.monday),
  'mon': DayNameToken(Weekday.monday),
  'tuesday': DayNameToken(Weekday.tuesday),
  'tue': DayNameToken(Weekday.tuesday),
  'wednesday': DayNameToken(Weekday.wednesday),
  'wed': DayNameToken(Weekday.wednesday),
  'thursday': DayNameToken(Weekday.thursday),
  'thu': DayNameToken(Weekday.thursday),
  'friday': DayNameToken(Weekday.friday),
  'fri': DayNameToken(Weekday.friday),
  'saturday': DayNameToken(Weekday.saturday),
  'sat': DayNameToken(Weekday.saturday),
  'sunday': DayNameToken(Weekday.sunday),
  'sun': DayNameToken(Weekday.sunday),
  'january': MonthNameToken(MonthName.jan),
  'jan': MonthNameToken(MonthName.jan),
  'february': MonthNameToken(MonthName.feb),
  'feb': MonthNameToken(MonthName.feb),
  'march': MonthNameToken(MonthName.mar),
  'mar': MonthNameToken(MonthName.mar),
  'april': MonthNameToken(MonthName.apr),
  'apr': MonthNameToken(MonthName.apr),
  'may': MonthNameToken(MonthName.may),
  'june': MonthNameToken(MonthName.jun),
  'jun': MonthNameToken(MonthName.jun),
  'july': MonthNameToken(MonthName.jul),
  'jul': MonthNameToken(MonthName.jul),
  'august': MonthNameToken(MonthName.aug),
  'aug': MonthNameToken(MonthName.aug),
  'september': MonthNameToken(MonthName.sep),
  'sep': MonthNameToken(MonthName.sep),
  'october': MonthNameToken(MonthName.oct),
  'oct': MonthNameToken(MonthName.oct),
  'november': MonthNameToken(MonthName.nov),
  'nov': MonthNameToken(MonthName.nov),
  'december': MonthNameToken(MonthName.dec),
  'dec': MonthNameToken(MonthName.dec),
  'first': OrdinalToken(OrdinalPosition.first),
  'second': OrdinalToken(OrdinalPosition.second),
  'third': OrdinalToken(OrdinalPosition.third),
  'fourth': OrdinalToken(OrdinalPosition.fourth),
  'fifth': OrdinalToken(OrdinalPosition.fifth),
  'min': IntervalUnitToken(IntervalUnit.min),
  'mins': IntervalUnitToken(IntervalUnit.min),
  'minute': IntervalUnitToken(IntervalUnit.min),
  'minutes': IntervalUnitToken(IntervalUnit.min),
  'hour': IntervalUnitToken(IntervalUnit.hours),
  'hours': IntervalUnitToken(IntervalUnit.hours),
  'hr': IntervalUnitToken(IntervalUnit.hours),
  'hrs': IntervalUnitToken(IntervalUnit.hours),
};

bool _isDigit(String ch) => ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

bool _isAlpha(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

bool _isAlphanumeric(String ch) => _isDigit(ch) || _isAlpha(ch);

bool _isWhitespace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';
