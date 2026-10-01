import 'ast.dart';
import 'error.dart';

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

class Token {
  final TokenKind kind;

  /// UTF-16 offsets into the input. Errors convert them to code points.
  final int start;
  final int end;

  Token(this.kind, this.start, this.end);
}

List<Token> tokenize(String input) => _Lexer(input).tokenize();

Span codePointSpan(String input, int start, int end) {
  final before = input.substring(0, start).runes.length;
  return Span(before, before + input.substring(start, end).runes.length);
}

/// Folds only `A`-`Z`: [String.toLowerCase] would also fold non-ASCII
/// letters, such as the Kelvin sign to `k`.
String asciiLower(String text) => String.fromCharCodes(
  text.codeUnits.map((c) => c >= 0x41 && c <= 0x5A ? c + 0x20 : c),
);

const _maxNumber = 2147483647;

class _Lexer {
  final String input;
  int pos = 0;

  _Lexer(this.input);

  List<Token> tokenize() {
    final tokens = <Token>[];
    while (true) {
      _advanceWhile(_isWhitespace);
      if (pos >= input.length) break;
      final start = pos;
      final c = input.codeUnitAt(pos);
      final TokenKind kind;
      if (tokens.isNotEmpty && tokens.last.kind is InToken) {
        _advanceWhile((c) => !_isWhitespace(c));
        kind = TimezoneToken(input.substring(start, pos));
      } else if (c == 0x2C) {
        pos++;
        kind = CommaToken();
      } else if (_isAlpha(c)) {
        kind = _word(start);
      } else if (_isDigit(c)) {
        kind = _digits(start);
      } else {
        throw _unexpectedCharacter(start);
      }
      tokens.add(Token(kind, start, pos));
    }
    return tokens;
  }

  void _advanceWhile(bool Function(int) matches) {
    while (pos < input.length && matches(input.codeUnitAt(pos))) {
      pos++;
    }
  }

  bool _isAt(int offset, bool Function(int) matches) =>
      pos + offset < input.length && matches(input.codeUnitAt(pos + offset));

  HronError _error(String message, int start) =>
      HronError.lex(message, codePointSpan(input, start, pos), input);

  TokenKind _word(int start) {
    _advanceWhile((c) => _isAlpha(c) || _isDigit(c) || c == 0x5F);
    final text = input.substring(start, pos);
    return _keywordMap[asciiLower(text)] ??
        (throw _error("unknown keyword '$text'", start));
  }

  TokenKind _digits(int start) {
    _advanceWhile(_isDigit);
    final digits = input.substring(start, pos);
    if (digits.length == 4 && _isIsoDateTail()) {
      pos += '-MM-DD'.length;
      return IsoDateToken(input.substring(start, pos));
    }
    if (_isAt(0, (c) => c == 0x3A)) return _time(start);
    final value = _numberValue(digits);
    if (value == null) {
      throw _error('number must be at most 2147483647', start);
    }
    if (pos + 2 <= input.length &&
        const {
          'st',
          'nd',
          'rd',
          'th',
        }.contains(asciiLower(input.substring(pos, pos + 2)))) {
      pos += 2;
      return OrdinalNumberToken(value);
    }
    return NumberToken(value);
  }

  bool _isIsoDateTail() {
    bool isDash(int c) => c == 0x2D;
    return _isAt(0, isDash) &&
        _isAt(1, _isDigit) &&
        _isAt(2, _isDigit) &&
        _isAt(3, isDash) &&
        _isAt(4, _isDigit) &&
        _isAt(5, _isDigit);
  }

  TokenKind _time(int start) {
    final colon = pos;
    pos++;
    _advanceWhile(_isDigit);
    final text = input.substring(start, pos);
    final hourDigits = colon - start;
    final minuteDigits = pos - colon - 1;
    if (hourDigits > 2 || minuteDigits != 2) {
      throw _error('time must be H:MM or HH:MM, got $text', start);
    }
    final hour = int.parse(input.substring(start, colon));
    final minute = int.parse(input.substring(colon + 1, pos));
    if (hour > 23 || minute > 59) {
      throw _error('time must be 00:00-23:59, got $text', start);
    }
    return TimeToken(hour, minute);
  }

  HronError _unexpectedCharacter(int start) {
    final rune = RuneIterator.at(input, start)..moveNext();
    final c = rune.current;
    // `'` is excluded because `'''` would not read as a quoted character.
    final shown = c >= 0x21 && c <= 0x7E && c != 0x27
        ? "'${String.fromCharCode(c)}'"
        : 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';
    pos = start + rune.currentSize;
    return _error('unexpected character $shown', start);
  }
}

/// Stops past [_maxNumber], so a run of any length neither overflows on the
/// VM nor loses precision on the web.
int? _numberValue(String digits) {
  var n = 0;
  for (final c in digits.codeUnits) {
    n = n * 10 + (c - 0x30);
    if (n > _maxNumber) return null;
  }
  return n;
}

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

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isAlpha(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Only these four separate tokens; any other whitespace is an unexpected
/// character.
bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
