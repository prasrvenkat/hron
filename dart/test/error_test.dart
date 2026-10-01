import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;

import 'package:hron/hron.dart';

import 'support/spec_cases.dart';

HronError parseError(String input) {
  try {
    Schedule.parse(input);
  } on HronError catch (e) {
    return e;
  }
  fail('$input parsed');
}

void main() {
  tz.initializeTimeZones();

  group('spans count code points', () {
    test('a lone high surrogate is one code point, shown by its value', () {
      final e = parseError('every \uD800 day');
      expect(e.kind, HronErrorKind.lex);
      expect(e.message, 'unexpected character U+D800');
      expect([e.span!.start, e.span!.end], [6, 7]);
    });

    test('a lone low surrogate is one code point, shown by its value', () {
      final e = parseError('\uDC00\uD800');
      expect(e.message, 'unexpected character U+DC00');
      expect([e.span!.start, e.span!.end], [0, 1]);
    });

    test('an astral character is one code point', () {
      final e = parseError('every \u{1F600} day');
      expect(e.message, 'unexpected character U+1F600');
      expect([e.span!.start, e.span!.end], [6, 7]);
    });

    test('a timezone of astral characters spans one code point for each', () {
      final e = parseError('every day at 09:00 in \u{1F600}/\u{1F600}');
      expect(e.message, startsWith('timezone must be UTC'));
      expect([e.span!.start, e.span!.end], [22, 25]);
      expect(e.displayRich().split('\n').last, '  ${' ' * 22}^^^');
    });
  });

  test('eval and cron errors render their message alone', () {
    expect(HronError.eval('no zone').displayRich(), 'error: no zone');
    expect(HronError.cron('bad cron').displayRich(), 'error: bad cron');
    for (final kind in [HronErrorKind.eval, HronErrorKind.cron]) {
      final withSpan = HronError(
        kind,
        'no zone',
        span: const Span(0, 1),
        input: 'x',
      );
      expect(withSpan.displayRich(), 'error: no zone', reason: '$kind');
    }
  });

  test('every spec parse_errors case holds on this platform', () async {
    final spec = await loadSpec();
    for (final tc in (spec['parse_errors'] as Map)['tests'] as List) {
      try {
        checkParseError(tc as Map<String, dynamic>);
      } on TestFailure catch (e) {
        fail('${tc['name']}: ${e.message}');
      }
    }
  }, testOn: '!vm');
}
