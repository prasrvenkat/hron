import 'package:hron/hron.dart';
import 'package:test/test.dart';

// dart test loads each test file on its own, so nothing here has loaded timezone data.
void main() {
  test('an Area/Location zone without timezone data is a setup error', () {
    const input = 'every day at 09:00 in America/New_York';
    expect(
      () => Schedule.parse(input),
      throwsA(
        isA<HronError>()
            .having((e) => e.kind, 'kind', HronErrorKind.parse)
            .having(
              (e) => e.message,
              'message',
              "timezone 'America/New_York' needs timezone data: call "
                  'initializeTimeZones() from '
                  'package:timezone/data/latest_all.dart before parsing',
            )
            .having((e) => [e.span!.start, e.span!.end], 'span', [22, 38]),
      ),
    );
  });

  test('UTC needs no timezone data', () {
    expect(
      Schedule.parse('every day at 09:00 in UTC').toString(),
      'every day at 09:00 in UTC',
    );
  });
}
