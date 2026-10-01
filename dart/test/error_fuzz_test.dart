import 'dart:convert';

import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import 'package:hron/hron.dart';

import 'support/spec_cases.dart';

const inputs = 6000;
const seed = 0x5EED4A0E;

const what = [
  r"'every' or 'on'",
  r"'day', 'weekday', 'weekend', a day name, 'week', 'month', 'year' or a number",
  r"a unit \('min', 'hours', 'days', 'weeks', 'months' or 'years'\)",
  r"'at'",
  r'a time \(HH:MM\)',
  r"'from'",
  r"'to'",
  r"'day', 'weekday', 'weekend' or a day name",
  r"'on'",
  r'a day name',
  r"'the'",
  r"a day such as 15th, 'last', an ordinal such as 'first', 'next', 'previous' or 'nearest'",
  r"'day', 'weekday' or a day name",
  r"'nearest'",
  r"'weekday'",
  r'a day such as 15th',
  r"a month name or 'the'",
  r"a day such as 15th, 'last' or an ordinal such as 'first'",
  r"'weekday' or a day name",
  r"'of'",
  r'a month name',
  r'a day number',
  r'a date \(YYYY-MM-DD, or a month and day\)',
  r'a date \(YYYY-MM-DD\)',
  r'a timezone',
];
const month = 'jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec';
// Dart's RegExp has no inline `(?i:...)`.
const day = '[0-9]+(?:[sS][tT]|[nN][dD]|[rR][dD]|[tT][hH])?';
const time = '[0-9]{1,2}:[0-9]{2}';

const clauseOrder = ['except', 'until', 'starting', 'during', 'in'];
final tokenSeparator = RegExp('[ \t\r\n]');

class Failure {
  final String input;
  final int start;
  final int end;
  final String spanned;

  Failure(this.input, this.start, this.end, this.spanned);
}

typedef Check = String? Function(RegExpMatch match, Failure failure);

class Template {
  final HronErrorKind kind;
  final RegExp regex;
  final Check check;

  Template(this.kind, String pattern, this.check)
    // dotAll, since a timezone in a message may hold U+2028, which `.` skips.
    : regex = RegExp(pattern, dotAll: true);
}

String? ensure(bool holds, String Function() problem) =>
    holds ? null : problem();

/// Saturates, since a digit run can be thousands of digits long.
int value(String text) {
  var n = 0;
  for (final c in text.codeUnits) {
    if (c < 0x30 || c > 0x39) break;
    n = n > 1000000000000 ? n : n * 10 + (c - 0x30);
  }
  return n;
}

String group(RegExpMatch match, String name) =>
    match.groupNames.contains(name) ? match.namedGroup(name) ?? '' : '';

String asciiLower(String text) => String.fromCharCodes(
  text.codeUnits.map((c) => c >= 0x41 && c <= 0x5A ? c + 0x20 : c),
);

String asciiUpper(String text) => String.fromCharCodes(
  text.codeUnits.map((c) => c >= 0x61 && c <= 0x7A ? c - 0x20 : c),
);

String trimSeparatorsEnd(String text) =>
    text.replaceFirst(RegExp(r'[ \t\r\n]+$'), '');

String? noCheck(RegExpMatch _, Failure _) => null;

/// From spec/README.md, "Lex errors" and "Parse errors". A `span` group must
/// equal the spanned text; every other group is read by its template's check.
final templates = [
  Template(HronErrorKind.lex, r"^unexpected character '(?<span>[!-&(-~])'$", (
    _,
    f,
  ) {
    final c = f.spanned.isEmpty ? ' ' : f.spanned;
    return ensure(
      !RegExp('^[A-Za-z0-9,]').hasMatch(c),
      () => "'$c' starts a token, so it is never unexpected",
    );
  }),
  Template(
    HronErrorKind.lex,
    r'^unexpected character U\+(?<code>[0-9A-F]{4,})$',
    (m, f) {
      final shown = int.parse(group(m, 'code'), radix: 16);
      final quotable = shown >= 0x21 && shown <= 0x7E && shown != 0x27;
      final runes = f.spanned.runes.toList();
      return ensure(
        runes.length == 1 && runes.single == shown && !quotable,
        () => "U+${group(m, 'code')} does not describe '${f.spanned}'",
      );
    },
  ),
  Template(
    HronErrorKind.lex,
    r"^unknown keyword '(?<span>[A-Za-z][A-Za-z0-9_]*)'$",
    noCheck,
  ),
  Template(
    HronErrorKind.lex,
    r'^time must be H:MM or HH:MM, got (?<span>(?<hour>[0-9]+):(?<minute>[0-9]*))$',
    (m, _) {
      final hour = group(m, 'hour');
      final minute = group(m, 'minute');
      return ensure(
        hour.length > 2 || minute.length != 2,
        () => '$hour:$minute is H:MM or HH:MM',
      );
    },
  ),
  Template(
    HronErrorKind.lex,
    r'^time must be 00:00-23:59, got (?<span>(?<hour>[0-9]{1,2}):(?<minute>[0-9]{2}))$',
    (m, _) {
      final hour = value(group(m, 'hour'));
      final minute = value(group(m, 'minute'));
      return ensure(
        hour > 23 || minute > 59,
        () => '$hour:$minute is in range',
      );
    },
  ),
  Template(HronErrorKind.lex, r'^number must be at most 2147483647$', (_, f) {
    final digits = RegExp(r'^[0-9]+$').hasMatch(f.spanned);
    return ensure(
      digits && value(f.spanned) > 2147483647,
      () => "'${f.spanned}' is not digits above 2147483647",
    );
  }),
  Template(HronErrorKind.parse, r'^empty expression$', (_, f) {
    final blank = trimSeparatorsEnd(f.input).isEmpty;
    return ensure(
      blank && f.start == 0 && f.end == 0,
      () => 'empty expression with span ${f.start}..${f.end}',
    );
  }),
  Template(
    HronErrorKind.parse,
    "^expected (?:${what.join('|')}), got (?:'(?<span>.+)'|(?<end>end of input))\$",
    (m, f) {
      if (m.namedGroup('end') == null) return null;
      final end = trimSeparatorsEnd(f.input).runes.length;
      return ensure(
        f.start == end && f.end == end,
        () => 'end of input at ${f.start}..${f.end}, expected $end..$end',
      );
    },
  ),
  Template(
    HronErrorKind.parse,
    r'^interval must be 1-2147483647, got (?<span>[0-9]+)$',
    (_, f) =>
        ensure(value(f.spanned) == 0, () => 'interval ${f.spanned} is valid'),
  ),
  Template(HronErrorKind.parse, '^day must be 1-31, got (?<span>$day)\$', (
    _,
    f,
  ) {
    final n = value(f.spanned);
    return ensure(n == 0 || n > 31, () => 'day $n is within 1-31');
  }),
  Template(
    HronErrorKind.parse,
    '^day must be 1-(?<max>[0-9]+) for (?<month>$month), got (?<span>$day)\$',
    (m, f) {
      final name = group(m, 'month');
      final length = switch (name) {
        'feb' => 29,
        'apr' || 'jun' || 'sep' || 'nov' => 30,
        _ => 31,
      };
      final max = value(group(m, 'max'));
      final n = value(f.spanned);
      return ensure(
        max == length && n > max && n <= 31,
        () => 'day $n against 1-$max for $name',
      );
    },
  ),
  Template(
    HronErrorKind.parse,
    '^day range must not run backwards: (?<a>$day) to (?<b>$day)\$',
    (m, f) {
      final a = group(m, 'a');
      final b = group(m, 'b');
      final spansBoth = f.spanned.startsWith(a) && f.spanned.endsWith(b);
      return ensure(
        spansBoth && value(a) > value(b),
        () => "$a to $b against the span '${f.spanned}'",
      );
    },
  ),
  Template(
    HronErrorKind.parse,
    '^time window must not run backwards: (?<from>$time) to (?<to>$time) '
    r'\(a window cannot cross midnight\)$',
    (m, f) {
      final from = group(m, 'from');
      final to = group(m, 'to');
      int minutes(String t) {
        final [hour, minute] = t.split(':');
        return value(hour) * 60 + value(minute);
      }

      final spansBoth = f.spanned.startsWith(from) && f.spanned.endsWith(to);
      return ensure(
        spansBoth && minutes(from) > minutes(to),
        () => "$from to $to against the span '${f.spanned}'",
      );
    },
  ),
  Template(
    HronErrorKind.parse,
    r'^date must be a calendar date from 0001-01-01 to 9999-12-31, got (?<span>[0-9]{4}-[0-9]{2}-[0-9]{2})$',
    (_, f) {
      final [y, m, d] = f.spanned.split('-').map(int.parse).toList();
      final date = DateTime.utc(y, m, d);
      final calendar =
          y >= 1 && date.year == y && date.month == m && date.day == d;
      return ensure(!calendar, () => '${f.spanned} is a calendar date');
    },
  ),
  Template(
    HronErrorKind.parse,
    r'^timezone must be UTC or an Area/Location name such as America/New_York, got (?<span>.+)$',
    noCheck,
  ),
  Template(
    HronErrorKind.parse,
    r"^duplicate '(?<keyword>except|until|starting|during|in)' clause$",
    (m, f) => ensure(
      group(m, 'keyword') == asciiLower(f.spanned),
      () =>
          "duplicate '${group(m, 'keyword')}' but the span holds '${f.spanned}'",
    ),
  ),
  Template(
    HronErrorKind.parse,
    r"^'(?<keyword>[a-z]+)' must come before '(?<last>[a-z]+)'$",
    (m, f) {
      final keyword = group(m, 'keyword');
      final last = group(m, 'last');
      final k = clauseOrder.indexOf(keyword);
      final l = clauseOrder.indexOf(last);
      final earlier = k >= 0 && l >= 0 && k < l;
      return ensure(
        earlier && keyword == asciiLower(f.spanned),
        () => "'$keyword' before '$last' with the span '${f.spanned}'",
      );
    },
  ),
  Template(
    HronErrorKind.parse,
    r"^unexpected '(?<span>.+)' after the schedule$",
    noCheck,
  ),
  Template(
    HronErrorKind.parse,
    '^until (?<month>$month) (?<day>[1-9][0-9]?) has no year: '
    r'add a starting date, or use an ISO date$',
    (m, f) {
      final words = f.spanned
          .split(tokenSeparator)
          .where((w) => w.isNotEmpty)
          .toList();
      final endsAtDay = trimSeparatorsEnd(f.spanned) == f.spanned;
      final matchesMessage =
          endsAtDay &&
          words.length == 3 &&
          asciiLower(words[0]) == 'until' &&
          asciiLower(words[1]).startsWith(group(m, 'month')) &&
          RegExp('^[0-9]').hasMatch(words[2]) &&
          value(words[2]).toString() == group(m, 'day');
      return ensure(
        matchesMessage,
        () =>
            "the span '${f.spanned}' is not "
            "'until ${group(m, 'month')} ${group(m, 'day')}'",
      );
    },
  ),
];

const fragments = [
  'every',
  'on',
  'at',
  'from',
  'to',
  'in',
  'IN',
  'of',
  'the',
  'last',
  'except',
  'until',
  'starting',
  'during',
  'nearest',
  'next',
  'previous',
  'day',
  'Days',
  'weekdays',
  'weekend',
  'week',
  'month',
  'years',
  'min',
  'hrs',
  'monday',
  'FRI',
  'jan',
  'february',
  'first',
  'fifth',
  '0',
  '1',
  '00',
  '15th',
  '31ST',
  '2nd',
  '2147483647',
  '2147483648',
  '99999999999999999999',
  '09:00',
  '9:5',
  '24:00',
  '9:',
  '17:30',
  '2026-02-28',
  '2026-02-30',
  '0000-01-01',
  '12026-03-15',
  ',',
  ':',
  '-',
  '/',
  "'",
  '"',
  '#',
  '~',
  '_',
  'UTC',
  'America/New_York',
  'Nope/Zone',
  'Europe/\u{130}stanbul',
  '\u{e9}',
  'e\u{301}',
  '\u{212a}',
  '\u{a0}',
  '\u{2028}',
  '\u{feff}',
  '\u{ff10}',
  '\u{1f600}',
  '\u{10ffff}',
  '\u{1d7d8}',
  '\u{0}',
  '\u{b}',
  '\u{c}',
  '\u{7f}',
  '\u{1b}',
  // Lone surrogates, which Rust strings cannot hold.
  '\uD800',
  '\uDFFF',
];
const separators = ['', ' ', ' ', ' ', '  ', '\t', '\r\n', '\n'];

const clauses = [
  'except dec 25',
  'except 2026-12-25, jan 1',
  'until 2027-12-31',
  'until dec 31',
  'starting 2026-01-01',
  'during jan, jul',
  'in UTC',
  'IN America/New_York',
];

/// Xorshift32: its 32-bit arithmetic gives the same inputs on the VM and the
/// web, where integers are doubles.
class Rng {
  int state;

  Rng(this.state);

  int next() {
    state ^= (state << 13) & 0xFFFFFFFF;
    state ^= state >> 17;
    state ^= (state << 5) & 0xFFFFFFFF;
    return state;
  }

  int below(int n) => next() % n;

  T pick<T>(List<T> items) => items[below(items.length)];
}

String randomText(Rng rng) {
  final out = StringBuffer();
  for (var i = 0, n = rng.below(12); i <= n; i++) {
    out
      ..write(rng.pick(separators))
      ..write(rng.pick(fragments));
  }
  return out.toString();
}

String mutate(Rng rng, String input) {
  final words = input.split(' ');
  final i = rng.below(words.length);
  switch (rng.below(7)) {
    case 0:
      words.removeAt(i);
    case 1:
      final j = rng.below(words.length);
      final word = words[i];
      words[i] = words[j];
      words[j] = word;
    case 2:
      words.insert(rng.below(words.length + 1), words[i]);
    case 3:
      final runes = input.runes.toList();
      return String.fromCharCodes(
        runes.sublist(0, rng.below(runes.length + 1)),
      );
    case 4:
      words[i] = asciiUpper(words[i]);
    case 5:
      words[i] = rng.pick(fragments);
    default:
      final fragment = rng.pick(fragments);
      final runes = words[i].runes.toList();
      runes.insertAll(rng.below(runes.length + 1), fragment.runes);
      words[i] = String.fromCharCodes(runes);
  }
  return words.join(' ');
}

String withClauses(Rng rng, String input) {
  final out = StringBuffer(input);
  for (var i = 0, n = rng.below(4); i <= n; i++) {
    out
      ..write(' ')
      ..write(rng.pick(clauses));
  }
  return out.toString();
}

String generate(Rng rng, List<String> corpus) {
  switch (rng.below(4)) {
    case 0:
      return randomText(rng);
    case 1:
      return withClauses(rng, corpus[rng.below(corpus.length)]);
    default:
      var input = corpus[rng.below(corpus.length)];
      for (var i = 0, n = rng.below(4); i < n; i++) {
        input = mutate(rng, input);
      }
      return input;
  }
}

Object check(String input, HronError error) {
  final kind = error.kind;
  final span = error.span;
  if (kind != HronErrorKind.lex && kind != HronErrorKind.parse) {
    return 'neither lex nor parse: ${kind.name}';
  }
  if (Schedule.validate(input)) return 'validate is true';
  if (error.input != input) return 'error input is ${jsonEncode(error.input)}';
  final runes = input.runes.toList();
  if (span == null ||
      span.start < 0 ||
      span.start > span.end ||
      span.end > runes.length) {
    return 'span ${span?.start}..${span?.end} outside 0..${runes.length}';
  }
  final failure = Failure(
    input,
    span.start,
    span.end,
    String.fromCharCodes(runes.sublist(span.start, span.end)),
  );

  final message = error.message;
  for (var index = 0; index < templates.length; index++) {
    final template = templates[index];
    if (template.kind != kind) continue;
    final match = template.regex.firstMatch(message);
    if (match == null) continue;

    if (match.groupNames.contains('span') &&
        match.namedGroup('span') != null &&
        match.namedGroup('span') != failure.spanned) {
      return "message echoes '${match.namedGroup('span')}' "
          "but the span holds '${failure.spanned}'";
    }
    final problem = template.check(match, failure);
    if (problem != null) return problem;

    final expectedSuggestion = message.startsWith('until ')
        ? "until ${group(match, 'month')} ${group(match, 'day')} starting YYYY-MM-DD"
        : null;
    if (error.suggestion != expectedSuggestion) {
      return 'suggestion ${error.suggestion}, expected $expectedSuggestion';
    }

    final rich = error.displayRich();
    if (rich.split('\n').length != 3 || !rich.startsWith('error: $message\n')) {
      return 'displayRich is not three lines: ${jsonEncode(rich)}';
    }
    return index;
  }
  return "${kind.name} message '$message' matches no template";
}

Future<List<String>> loadCorpus() async {
  final spec = await loadSpec();
  final parse = (spec['parse'] as Map).values.whereType<Map>();
  return [
    for (final section in parse)
      for (final tc in section['tests'] as List) tc['input'] as String,
    for (final tc in (spec['parse_errors'] as Map)['tests'] as List)
      tc['input'] as String,
  ];
}

void main() {
  tz.initializeTimeZones();

  test('generated inputs fail only with spec errors', () async {
    final corpus = await loadCorpus();
    final rng = Rng(seed);
    final hits = List.filled(templates.length, 0);
    var parsed = 0;
    final failures = <String>[];

    for (var i = 0; i < inputs; i++) {
      final input = generate(rng, corpus);
      try {
        Schedule.parse(input);
        parsed++;
      } on HronError catch (error) {
        final result = check(input, error);
        if (result is int) {
          hits[result]++;
        } else {
          failures.add('${jsonEncode(input)}: $result');
        }
      } catch (error) {
        failures.add('${jsonEncode(input)}: parse threw $error');
      }
    }

    expect(
      failures,
      isEmpty,
      reason:
          '${failures.length} failures, first ones:\n'
          '${failures.take(20).join('\n')}',
    );
    expect(
      parsed,
      greaterThan(inputs ~/ 20),
      reason: 'only $parsed inputs parsed; the generator has drifted',
    );
    final unused = [
      for (var i = 0; i < templates.length; i++)
        if (hits[i] == 0) templates[i].regex.pattern,
    ];
    expect(unused, isEmpty, reason: 'templates no input produced');
  });
}
