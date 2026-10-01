import 'dart:convert';
import 'dart:io';

import 'package:hron/hron.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart';

TZDateTime parseZoned(String s) {
  final bracket = s.indexOf('[');
  final zone = s.substring(bracket + 1, s.length - 1);
  final instant = DateTime.parse(s.substring(0, bracket));
  return TZDateTime.fromMillisecondsSinceEpoch(
    zone == 'UTC' ? UTC : getLocation(zone),
    instant.millisecondsSinceEpoch,
  );
}

String two(int n) => n.toString().padLeft(2, '0');

String formatZoned(TZDateTime t) {
  final offset = t.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final date =
      '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}';
  final time = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  final zone =
      '$sign${two(offset.inHours.abs())}:${two(offset.inMinutes.abs() % 60)}';
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

Map<String, Object?> run(Map<String, dynamic> c) {
  try {
    return {'ok': true, 'result': evaluate(c)};
  } on HronError catch (e) {
    return {
      'ok': false,
      'error': {'kind': e.kind.name},
    };
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
    stdout.writeln(jsonEncode({'id': c['id'], ...run(c)}));
    await stdout.flush();
  }
}
