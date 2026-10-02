// Reads spec/api.json through dart:io and finds its members through
// dart:mirrors, which only the VM has.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:mirrors';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart';

import 'package:hron/hron.dart';

Map<String, dynamic> loadApi() {
  var dir = Directory.current.path;
  if (p.basename(dir) == 'dart') dir = p.dirname(dir);
  final file = File(p.join(dir, 'spec', 'api.json'));
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

// The spec/api.json "dart" note: equals is == with hashCode.
List<String> dartMembers(String name) =>
    name == 'equals' ? ['==', 'hashCode'] : [name];

final now = TZDateTime.utc(2026, 2, 6, 12);
final later = TZDateTime.utc(2026, 2, 9, 12);

final arguments = <String, List<Object?>>{
  'parse': ['every day at 09:00'],
  'fromCron': ['0 9 * * *'],
  'validate': ['every day at 09:00'],
  'nextFrom': [now],
  'nextNFrom': [now, 3],
  'previousFrom': [now],
  'matches': [now],
  'occurrences': [now],
  'between': [now, later],
  'toCron': [],
  'toString': [],
  'equals': [Schedule.parse('every day at 9:00')],
  'displayRich': [],
};

final constructorArguments = <String, List<Object?>>{
  'lex': ['unexpected character', const Span(0, 1), '!'],
  'parse': ['expected time', const Span(0, 1), 'x'],
  'eval': ['no occurrence'],
  'cron': ['expected 5 cron fields, got 1'],
};

Matcher nullOr(Matcher matcher) => anyOf(isNull, matcher);

final dartTypes = <String, Matcher>{
  'Schedule': isA<Schedule>(),
  'bool': isA<bool>(),
  'string': isA<String>(),
  'string?': nullOr(isA<String>()),
  'ZonedDateTime?': nullOr(isA<TZDateTime>()),
  'ZonedDateTime[]': isA<List<TZDateTime>>(),
  'Iterator<ZonedDateTime>': isA<Iterable<TZDateTime>>(),
  'ScheduleExpr': isA<ScheduleExpr>(),
  'Exception[]': isA<List<ExceptionSpec>>(),
  'UntilSpec?': nullOr(isA<UntilSpec>()),
  'Date?': nullOr(matches(RegExp(r'^\d{4}-\d{2}-\d{2}$'))),
  'MonthName[]': isA<List<MonthName>>(),
  'ErrorKind': isA<HronErrorKind>(),
  'Span?': nullOr(isA<Span>()),
};

// Two schedules, so each getter type is checked with a value and without one.
final gettersFull = Schedule.parse(
  'every day at 09:00 except dec 25 until 2027-12-31 starting 2026-01-01 '
  'during jan, feb in America/New_York',
);
final gettersEmpty = Schedule.parse('every day at 09:00');

List<String> typeProblems(String where, String type, Object? value) {
  final matcher = dartTypes[type];
  if (matcher == null) return ['$where: no Dart type for $type'];
  if (!matcher.matches(value, {})) return ['$where: $value is not a $type'];
  return [];
}

List<String> callProblems(
  String where,
  Map<String, dynamic> entry,
  InstanceMirror Function(List<Object?>) call,
) {
  final name = entry['name'] as String;
  final args = arguments[name];
  if (args == null) return ['$where: no arguments for $name'];
  final params = (entry['params'] as List).length;
  if (args.length != params) {
    return [
      '$where: api.json has $params params, arguments has ${args.length}',
    ];
  }
  final returns = entry['returns'] as String?;
  if (returns == null) return ['$where: api.json gives no return type'];
  return typeProblems(where, returns, call(args).reflectee);
}

List<String> methodProblems(
  ClassMirror owner,
  String name,
  int params, {
  required bool isStatic,
}) {
  final problems = <String>[];
  for (final member in dartMembers(name)) {
    final where = '${MirrorSystem.getName(owner.simpleName)}.$member';
    final declaration = owner.declarations[Symbol(member)];
    if (declaration is! MethodMirror || declaration.isPrivate) {
      problems.add('$where is not declared');
    } else if (declaration.isStatic != isStatic) {
      problems.add('$where is ${isStatic ? 'not ' : ''}static');
    } else if (!declaration.isGetter &&
        declaration.parameters.length != params) {
      problems.add('$where takes ${declaration.parameters.length} params');
    }
  }
  return problems;
}

List<String> getterProblems(ClassMirror owner, String name) {
  final where = '${MirrorSystem.getName(owner.simpleName)}.$name';
  final declaration = owner.declarations[Symbol(name)];
  final readable = switch (declaration) {
    VariableMirror(isFinal: true) => true,
    MethodMirror(isGetter: true) => true,
    _ => false,
  };
  if (!readable) return ['$where is not a final field or getter'];
  if (owner.declarations.containsKey(Symbol('$name='))) {
    return ['$where has a setter'];
  }
  return [];
}

List<String> apiProblems(Map<String, dynamic> api) {
  final problems = <String>[];
  final schedule = reflectClass(Schedule);
  final error = reflectClass(HronError);
  final scheduleSpec = api['schedule'] as Map<String, dynamic>;
  final errorSpec = api['error'] as Map<String, dynamic>;
  final instance = reflect(Schedule.parse('every day at 09:00'));

  for (final entry in scheduleSpec['staticMethods'] as List) {
    final name = entry['name'] as String;
    final where = 'Schedule.$name';
    final found = methodProblems(
      schedule,
      name,
      (entry['params'] as List).length,
      isStatic: true,
    );
    problems.addAll(found);
    if (found.isNotEmpty) continue;
    problems.addAll(
      callProblems(where, entry, (args) => schedule.invoke(Symbol(name), args)),
    );
  }

  for (final entry in scheduleSpec['instanceMethods'] as List) {
    final name = entry['name'] as String;
    final where = 'Schedule#$name';
    final found = methodProblems(
      schedule,
      name,
      (entry['params'] as List).length,
      isStatic: false,
    );
    problems.addAll(found);
    if (found.isNotEmpty) continue;
    problems.addAll(
      callProblems(
        where,
        entry,
        (args) => instance.invoke(Symbol(dartMembers(name).first), args),
      ),
    );
  }

  for (final entry in scheduleSpec['getters'] as List) {
    final name = entry['name'] as String;
    final found = getterProblems(schedule, name);
    problems.addAll(found);
    if (found.isNotEmpty) continue;
    for (final value in [gettersFull, gettersEmpty]) {
      problems.addAll(
        typeProblems(
          'Schedule.$name of $value',
          entry['type'] as String,
          reflect(value).getField(Symbol(name)).reflectee,
        ),
      );
    }
  }

  final kinds = (errorSpec['kinds'] as List).cast<String>();
  final dartKinds = [for (final kind in HronErrorKind.values) kind.name];
  for (final kind in kinds) {
    if (!dartKinds.contains(kind)) problems.add('HronErrorKind has no $kind');
  }
  for (final kind in dartKinds) {
    if (!kinds.contains(kind)) problems.add('api.json has no kind $kind');
  }

  final parseError = _parseError('every weekday at 09:00 until dec 31');
  for (final entry in errorSpec['properties'] as List) {
    final name = entry['name'] as String;
    final found = getterProblems(error, name);
    problems.addAll(found);
    if (found.isNotEmpty) continue;
    problems.addAll(
      typeProblems(
        'HronError.$name',
        entry['type'] as String,
        reflect(parseError).getField(Symbol(name)).reflectee,
      ),
    );
  }

  for (final entry in errorSpec['methods'] as List) {
    final name = entry['name'] as String;
    final found = methodProblems(
      error,
      name,
      (entry['params'] as List).length,
      isStatic: false,
    );
    problems.addAll(found);
    if (found.isNotEmpty) continue;
    problems.addAll(
      callProblems(
        'HronError#$name',
        entry,
        (args) => reflect(parseError).invoke(Symbol(name), args),
      ),
    );
  }

  for (final name in (errorSpec['constructors'] as List).cast<String>()) {
    final where = 'HronError.$name';
    final declaration = error.declarations[Symbol(where)];
    if (declaration is! MethodMirror || !declaration.isConstructor) {
      problems.add('$where is not a constructor');
      continue;
    }
    final args = constructorArguments[name];
    if (args == null) {
      problems.add('$where: no arguments');
      continue;
    }
    final built = error.newInstance(Symbol(name), args).reflectee as HronError;
    if (built.kind.name != name) problems.add('$where builds ${built.kind}');
  }

  return problems;
}

HronError _parseError(String input) {
  try {
    Schedule.parse(input);
  } on HronError catch (e) {
    return e;
  }
  fail('$input parsed');
}

Map<String, dynamic> copyOf(Map<String, dynamic> api) =>
    jsonDecode(jsonEncode(api)) as Map<String, dynamic>;

void main() {
  tz.initializeTimeZones();
  final api = loadApi();

  test('every spec/api.json member is present and returns its type', () {
    expect(apiProblems(api), isEmpty);
  });

  group('the check fails on a name Dart lacks:', () {
    final fakes = <String, void Function(Map<String, dynamic>)>{
      'static method': (copy) => (copy['schedule']['staticMethods'] as List)
          .add({'name': 'frobnicate', 'params': [], 'returns': 'string'}),
      'instance method': (copy) => (copy['schedule']['instanceMethods'] as List)
          .add({'name': 'frobnicate', 'params': [], 'returns': 'string'}),
      'getter': (copy) => (copy['schedule']['getters'] as List).add({
        'name': 'frobnicate',
        'type': 'string',
      }),
      'error property': (copy) => (copy['error']['properties'] as List).add({
        'name': 'frobnicate',
        'type': 'string',
      }),
      'error method': (copy) => (copy['error']['methods'] as List).add({
        'name': 'frobnicate',
        'params': [],
        'returns': 'string',
      }),
      'error constructor': (copy) =>
          (copy['error']['constructors'] as List).add('frobnicate'),
      'error kind': (copy) =>
          (copy['error']['kinds'] as List).add('frobnicate'),
    };
    for (final MapEntry(key: section, value: addFake) in fakes.entries) {
      test(section, () {
        final copy = copyOf(api);
        addFake(copy);
        expect(apiProblems(copy), [contains('frobnicate')]);
      });
    }
  });

  test('the check fails on a member whose type is wrong', () {
    final copy = copyOf(api);
    (copy['schedule']['getters'] as List).add({
      'name': 'timezone',
      'type': 'bool',
    });
    expect(
      apiProblems(copy),
      allOf(isNotEmpty, everyElement(contains('Schedule.timezone'))),
    );
  });

  test('the check fails on a member it cannot call', () {
    final copy = copyOf(api);
    (copy['schedule']['instanceMethods'] as List).add({
      'name': 'hashCode',
      'params': [],
      'returns': 'string',
    });
    expect(apiProblems(copy), ['Schedule#hashCode: no arguments for hashCode']);
  });
}
