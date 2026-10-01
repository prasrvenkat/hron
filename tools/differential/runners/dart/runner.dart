import 'dart:convert';
import 'dart:io';

import 'package:hron/hron.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart';

final zoned = RegExp(r'^(.+?)(?:Z|([+-])(\d\d):(\d\d)(?::(\d\d))?)\[(.+)\]$');

// DateTime.parse rejects an offset with seconds, so the offset is applied here.
TZDateTime parseZoned(String s) {
  final match = zoned.firstMatch(s)!;
  final wall = DateTime.parse('${match[1]}Z');
  final offset = Duration(
    hours: int.parse(match[3] ?? '0'),
    minutes: int.parse(match[4] ?? '0'),
    seconds: int.parse(match[5] ?? '0'),
  );
  final instant = match[2] == '-' ? wall.add(offset) : wall.subtract(offset);
  final zone = match[6]!;
  return TZDateTime.from(instant, zone == 'UTC' ? UTC : getLocation(zone));
}

String two(int n) => n.toString().padLeft(2, '0');

String formatZoned(TZDateTime t) {
  final offset = t.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final date =
      '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
  final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  final seconds = offset.inSeconds.abs();
  var zone = '$sign${two(seconds ~/ 3600)}:${two(seconds ~/ 60 % 60)}';
  if (seconds % 60 != 0) zone += ':${two(seconds % 60)}';
  return '${date}T$time$zone[${t.location.name}]';
}

String? formatOrNull(TZDateTime? t) => t == null ? null : formatZoned(t);

Object? evaluate(Map<String, dynamic> c) {
  final String op = c['op'];
  final String expr = c['expr'];
  if (op == 'fromCron') return Schedule.fromCron(expr).toString();
  final schedule = Schedule.parse(expr);
  TZDateTime time(String field) => parseZoned(c[field] as String);
  return switch (op) {
    'parse' => schedule.toString(),
    'toCron' => schedule.toCron(),
    'next' => formatOrNull(schedule.nextFrom(time('now'))),
    'nextN' =>
      schedule.nextNFrom(time('now'), c['n']).map(formatZoned).toList(),
    'prev' => formatOrNull(schedule.previousFrom(time('now'))),
    'matches' => schedule.matches(time('datetime')),
    'between' =>
      schedule.between(time('from'), time('to')).map(formatZoned).toList(),
    'occurrences' =>
      schedule.occurrences(time('from')).take(c['n']).map(formatZoned).toList(),
    _ => throw ArgumentError('unknown op $op'),
  };
}

Map<String, Object?> details(HronError e) => {
  'kind': e.kind.name,
  'message': e.message,
  'span': e.span == null ? null : [e.span!.start, e.span!.end],
  'suggestion': e.suggestion,
};

Map<String, Object?> run(Map<String, dynamic> c) {
  try {
    return {'ok': true, 'result': evaluate(c)};
  } on HronError catch (e) {
    return {'ok': false, 'error': details(e)};
  } catch (e) {
    return {
      'ok': false,
      'error': {'kind': 'crash', 'message': e.toString()},
    };
  }
}

Future<void> main() async {
  tz.initializeTimeZones();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    final Map<String, dynamic> c = jsonDecode(line);
    final watch = Stopwatch()..start();
    final outcome = run(c);
    final micros = watch.elapsedMicroseconds;
    stdout.writeln(jsonEncode({'id': c['id'], ...outcome, 'micros': micros}));
    await stdout.flush();
  }
}
