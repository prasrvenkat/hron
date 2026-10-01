import 'dart:convert';

import 'package:test/test.dart';

import 'package:hron/hron.dart';

/// Reads spec/tests.json in a VM isolate, so a test can read it on the web too.
Future<Map<String, dynamic>> loadSpec() async {
  final channel = spawnHybridCode(r'''
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

void hybridMain(StreamChannel<Object?> channel) {
  final local = File('../spec/tests.json');
  final spec = local.existsSync() ? local : File('spec/tests.json');
  channel.sink.add(spec.readAsStringSync());
}
''');
  return jsonDecode(await channel.stream.first as String)
      as Map<String, dynamic>;
}

/// Fails a case carrying a field outside [fields] or the labels `name` and
/// `description`: a field the runner does not check asserts nothing.
void checkFields(Map<String, dynamic> tc, Set<String> fields) {
  final unknown = tc.keys.toSet().difference({
    ...fields,
    'name',
    'description',
  });
  if (unknown.isNotEmpty) {
    fail('case has fields this runner does not check: $unknown');
  }
}

/// Fails a case that carries none of [fields]: a skipped case checks nothing.
void requireAssertion(Map<String, dynamic> tc, List<String> fields) {
  if (!fields.any(tc.containsKey)) {
    fail('case has none of the assertion fields $fields');
  }
}

const errorFields = {'kind', 'message', 'span', 'suggestion'};

void checkParseError(Map<String, dynamic> tc) {
  checkFields(tc, {'input', 'error', 'display'});
  requireAssertion(tc, ['error']);
  final input = tc['input'] as String;
  final expected = tc['error'] as Map<String, dynamic>;
  final unknown = expected.keys.toSet().difference(errorFields);
  if (unknown.isNotEmpty) {
    fail('error has fields this runner does not check: $unknown');
  }

  expect(Schedule.validate(input), isFalse, reason: 'validate');
  final HronError error;
  try {
    Schedule.parse(input);
    fail('parse succeeded');
  } on HronError catch (e) {
    error = e;
  }
  expect(error.kind.name, expected['kind'], reason: 'kind');
  expect(error.message, expected['message'], reason: 'message');
  expect(
    [error.span?.start, error.span?.end],
    expected['span'],
    reason: 'span',
  );
  expect(error.suggestion, expected['suggestion'], reason: 'suggestion');
  if (tc.containsKey('display')) {
    expect(error.displayRich(), tc['display'], reason: 'displayRich');
  }
}
