// dart:mirrors exists only on the VM.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:mirrors';

import 'package:hron/hron.dart';
import 'package:test/test.dart';

const internal = 'package:hron/src/';

const parts = {
  'DateSpec',
  'DateTarget',
  'DayFilter',
  'DayOfMonthSpec',
  'DayOfMonthTarget',
  'DayRange',
  'DayRepeat',
  'DaysTarget',
  'EveryDay',
  'ExceptionSpec',
  'IntervalRepeat',
  'IntervalUnit',
  'IsoDate',
  'IsoException',
  'IsoUntil',
  'LastDayTarget',
  'LastWeekdayTarget',
  'LastWeekdayYearTarget',
  'MonthName',
  'MonthRepeat',
  'MonthTarget',
  'NamedDate',
  'NamedException',
  'NamedUntil',
  'NearestDirection',
  'NearestWeekdayTarget',
  'OrdinalPosition',
  'OrdinalWeekdayMonthTarget',
  'OrdinalWeekdayTarget',
  'ScheduleExpr',
  'SingleDate',
  'SingleDay',
  'SpecificDays',
  'TimeOfDay',
  'UntilSpec',
  'WeekRepeat',
  'Weekday',
  'WeekdayFilter',
  'WeekendFilter',
  'YearRepeat',
  'YearTarget',
};

Iterable<TypeMirror> typesIn(TypeMirror type) sync* {
  yield type;
  for (final argument in type.typeArguments) {
    yield* typesIn(argument);
  }
}

String? libraryOf(TypeMirror type) => switch (type.owner) {
  LibraryMirror(:final uri) => uri.toString(),
  _ => null,
};

String nameOf(DeclarationMirror mirror) =>
    MirrorSystem.getName(mirror.simpleName);

void main() {
  final hron =
      currentMirrorSystem().libraries[Uri.parse('package:hron/hron.dart')]!;
  final exports = {
    for (final dependency in hron.libraryDependencies)
      if (dependency.isExport)
        dependency.targetLibrary!.uri.toString(): dependency,
  };
  final ast = exports['${internal}ast.dart']!.targetLibrary!;
  final shown = {
    for (final combinator in exports['${internal}ast.dart']!.combinators)
      ...combinator.identifiers.map(MirrorSystem.getName),
  };
  final partClasses = [
    for (final name in parts) ast.declarations[Symbol(name)] as ClassMirror,
  ];

  test('the library exports its errors and the parts, and nothing else', () {
    expect(
      exports.keys,
      unorderedEquals(['${internal}error.dart', '${internal}ast.dart']),
    );
    expect(exports['${internal}error.dart']!.combinators, isEmpty);
    final combinators = exports['${internal}ast.dart']!.combinators;
    expect(combinators.every((c) => c.isShow), isTrue);
    expect(shown, unorderedEquals(parts));
  });

  test('every public type in ast.dart is a part, except ScheduleData', () {
    final public = [
      for (final declaration in ast.declarations.values)
        if (declaration is ClassMirror && !declaration.isPrivate)
          nameOf(declaration),
    ];
    expect(public, unorderedEquals({...parts, 'ScheduleData'}));
  });

  test(
    'every type a public member of Schedule takes or returns is exported',
    () {
      final hidden = <String>[];
      for (final member in reflectClass(
        Schedule,
      ).declarations.values.whereType<MethodMirror>()) {
        if (member.isPrivate) continue;
        final signature = [
          member.returnType,
          for (final parameter in member.parameters) parameter.type,
        ];
        for (final type in signature.expand(typesIn)) {
          final library = libraryOf(type);
          if (library == null || !library.startsWith(internal)) continue;
          final exported =
              library == '${internal}error.dart' ||
              shown.contains(nameOf(type));
          if (!exported) hidden.add('${nameOf(member)}: ${nameOf(type)}');
        }
      }
      expect(hidden, isEmpty);
    },
  );

  test('every field of every part is final, with no setter', () {
    final writable = [
      for (final part in partClasses)
        for (final declaration in part.declarations.values)
          if (declaration is VariableMirror &&
                  !declaration.isStatic &&
                  !declaration.isFinal ||
              declaration is MethodMirror && declaration.isSetter)
            '${nameOf(part)}.${nameOf(declaration)}',
    ];
    expect(writable, isEmpty);
  });

  test(
    'every part that is not an enum or a sealed base has == and hashCode',
    () {
      final missing = [
        for (final part in partClasses)
          if (!part.isEnum && !part.isAbstract)
            for (final member in [#==, #hashCode])
              if (!part.declarations.containsKey(member))
                '${nameOf(part)}.${MirrorSystem.getName(member)}',
      ];
      expect(missing, isEmpty);
    },
  );

  test('another library cannot implement Schedule', () async {
    final directory = Directory.systemTemp.createTempSync('hron_final_');
    addTearDown(() => directory.deleteSync(recursive: true));
    final mock = File('${directory.path}/mock.dart')
      ..writeAsStringSync('''
import 'package:hron/hron.dart';

abstract class MockSchedule implements Schedule {}

void main() {}
''');
    await expectLater(
      Isolate.spawnUri(
        mock.uri,
        [],
        null,
        packageConfig: Isolate.packageConfigSync,
      ),
      throwsA(
        isA<IsolateSpawnException>().having(
          (e) => e.message,
          'message',
          contains("'Schedule' can't be implemented outside of its library"),
        ),
      ),
    );
  });
}
