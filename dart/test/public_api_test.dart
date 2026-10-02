// dart:mirrors exists only on the VM.
@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:hron/hron.dart';
import 'package:test/test.dart';

const internal = 'package:hron/src/';

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

void main() {
  final hron =
      currentMirrorSystem().libraries[Uri.parse('package:hron/hron.dart')]!;

  test('the library exports only its errors from src', () {
    expect(
      [
        for (final dependency in hron.libraryDependencies)
          if (dependency.isExport) dependency.targetLibrary!.uri.toString(),
      ],
      ['${internal}error.dart'],
    );
  });

  test('no public member of Schedule takes or returns a schedule part', () {
    final leaks = <String>[];
    for (final member in reflectClass(
      Schedule,
    ).declarations.values.whereType<MethodMirror>()) {
      if (member.isPrivate) continue;
      final signature = [
        member.returnType,
        for (final parameter in member.parameters) parameter.type,
      ];
      for (final type in signature.expand(typesIn)) {
        if (libraryOf(type)?.startsWith(internal) ?? false) {
          leaks.add(
            '${MirrorSystem.getName(member.simpleName)}: '
            '${MirrorSystem.getName(type.simpleName)}',
          );
        }
      }
    }
    expect(leaks, isEmpty);
  });
}
