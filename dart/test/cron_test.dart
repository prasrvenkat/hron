import 'package:hron/hron.dart';
import 'package:test/test.dart';
import 'package:timezone/timezone.dart';

// Two years around 2044-02-29, a leap day in a February with five Mondays.
final windowStart = DateTime.utc(2043, 6, 1);
final windowEnd = DateTime.utc(2045, 6, 1);
final windowDays = [
  for (
    var d = windowStart;
    d.isBefore(windowEnd);
    d = d.add(const Duration(days: 1))
  )
    d,
];
// Comparing every occurrence is the slow part, on the web above all.
const fullCompareLimit = 20000;

const bothDays =
    'not expressible in hron: cron fires on either the day of month or the day of week';
const intervalDays =
    'not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days';

String cronMessage(Object? Function() convert) {
  try {
    convert();
  } on HronError catch (e) {
    expect(e.kind, HronErrorKind.cron, reason: e.message);
    return e.message;
  }
  fail('expected a cron error');
}

String fromCron(String cron) => Schedule.fromCron(cron).toString();

String fromCronError(String cron) => cronMessage(() => fromCron(cron));

typedef DayRule = bool Function(DateTime date);

/// A cron matcher written from the cron rules alone, sharing no code with the
/// package. It expects valid syntax.
class NaiveCron {
  NaiveCron._(
    this.minutes,
    this.hours,
    this.months,
    this.dom,
    this.dow, {
    required this.domIsEveryDay,
    required this.dowIsList,
  });

  factory NaiveCron(String cron) {
    final text = switch (cron.trim().toLowerCase()) {
      '@yearly' || '@annually' => '0 0 1 1 *',
      '@monthly' => '0 0 1 * *',
      '@weekly' => '0 0 * * 0',
      '@daily' || '@midnight' => '0 0 * * *',
      '@hourly' => '0 * * * *',
      final other => other,
    };
    final f = text.split(RegExp(r'\s+'));
    expect(f, hasLength(5), reason: 'naive matcher given $text');
    DayRule? dom;
    var domIsEveryDay = false;
    switch (f[2]) {
      case '*' || '?':
        break;
      case 'l':
        dom = (d) => d.day == daysIn(d);
      case 'lw':
        dom = (d) => d.day == weekdaysOf(d).last;
      case final day when day.endsWith('w'):
        final n = naiveNumber(day.substring(0, day.length - 1), const []);
        dom = (d) {
          var nearest = weekdaysOf(d).first;
          for (final w in weekdaysOf(d)) {
            if ((w - n).abs() < (nearest - n).abs()) nearest = w;
          }
          return n <= daysIn(d) && d.day == nearest;
        };
      case final days:
        final set = naiveSet(days, 1, 31, 31, const []);
        domIsEveryDay = set.skip(1).every((b) => b);
        dom = (d) => set[d.day];
    }
    DayRule? dow;
    var dowIsList = false;
    switch (f[4]) {
      case '*' || '?':
        break;
      case final day when day.contains('#'):
        final hash = day.indexOf('#');
        final weekday = naiveNumber(day.substring(0, hash), dayNames) % 7;
        final n = naiveNumber(day.substring(hash + 1), const []);
        dow = (d) => sundayZero(d) == weekday && (d.day - 1) ~/ 7 + 1 == n;
      case final day when day.endsWith('l'):
        final weekday =
            naiveNumber(day.substring(0, day.length - 1), dayNames) % 7;
        dow = (d) => sundayZero(d) == weekday && d.day + 7 > daysIn(d);
      case final days:
        final set = naiveSet(days, 0, 7, 6, dayNames);
        set[0] |= set[7];
        dowIsList = true;
        dow = (d) => set[sundayZero(d)];
    }
    return NaiveCron._(
      naiveSet(f[0], 0, 59, 59, const []),
      naiveSet(f[1], 0, 23, 23, const []),
      naiveSet(f[3], 1, 12, 12, monthNames),
      dom,
      dow,
      domIsEveryDay: domIsEveryDay,
      dowIsList: dowIsList,
    );
  }

  final List<bool> minutes;
  final List<bool> hours;
  final List<bool> months;
  final DayRule? dom;
  final DayRule? dow;
  final bool domIsEveryDay;
  final bool dowIsList;

  List<(int, int)> times() => [
    for (var hour = 0; hour < 24; hour++)
      for (var minute = 0; minute < 60; minute++)
        if (hours[hour] && minutes[minute]) (hour, minute),
  ];

  bool firesOn(DateTime d) {
    final a = dom?.call(d);
    final b = dow?.call(d);
    final dayMatches = a == null ? (b ?? true) : (b == null ? a : a || b);
    return months[d.month] && dayMatches;
  }

  bool get bothDaysRestricted => dom != null && dow != null;

  bool get daysCarryAnInterval =>
      (dom == null && (dow == null || dowIsList)) ||
      (domIsEveryDay && dow == null);
}

const monthNames = [
  '',
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];
const dayNames = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

int daysIn(DateTime d) => DateTime.utc(d.year, d.month + 1, 0).day;

int sundayZero(DateTime d) => d.weekday % 7;

List<int> weekdaysOf(DateTime d) => [
  for (var n = 1; n <= daysIn(d); n++)
    if (DateTime.utc(d.year, d.month, n).weekday <= DateTime.friday) n,
];

int naiveNumber(String text, List<String> names) {
  final index = names.indexOf(text);
  if (index >= 0) return index;
  final n = int.tryParse(text);
  return n == null || n > 1000000 ? 1000000 : n;
}

List<bool> naiveSet(
  String field,
  int min,
  int max,
  int starMax,
  List<String> names,
) {
  final set = List.filled(max + 1, false);
  for (final item in field.split(',')) {
    final slash = item.indexOf('/');
    final range = slash < 0 ? item : item.substring(0, slash);
    final step = slash < 0 ? null : naiveNumber(item.substring(slash + 1), []);
    final dash = range.indexOf('-');
    final int low;
    final int high;
    if (range == '*') {
      (low, high) = (min, starMax);
    } else if (dash >= 0) {
      low = naiveNumber(range.substring(0, dash), names);
      high = naiveNumber(range.substring(dash + 1), names);
    } else {
      low = naiveNumber(range, names);
      high = step == null ? low : (low > starMax ? low : starMax);
    }
    for (var value = low; value <= high; value += step ?? 1) {
      set[value] = true;
    }
  }
  return set;
}

TZDateTime utc(DateTime d, [int hour = 0, int minute = 0]) =>
    TZDateTime.utc(d.year, d.month, d.day, hour, minute);

DateTime at(DateTime d, (int, int) time) =>
    DateTime.utc(d.year, d.month, d.day, time.$1, time.$2);

DateTime? wall(TZDateTime? t) =>
    t == null ? null : DateTime.utc(t.year, t.month, t.day, t.hour, t.minute);

const oneSecond = Duration(seconds: 1);
const oneDay = Duration(days: 1);

void assertFiresAs(Schedule schedule, NaiveCron cron, String label) {
  final times = cron.times();
  final days = windowDays.where(cron.firesOn).toList();
  if (days.length * times.length <= fullCompareLimit) {
    assertEachOccurrence(schedule, days, times, windowEnd, label);
    return;
  }
  final earlyEnd = days[1].add(oneDay);
  assertEachOccurrence(schedule, days.sublist(0, 2), times, earlyEnd, label);
  // Too many to compare one by one. In UTC an hron schedule fires at the same
  // times on every day it fires, so the two days compared in full stand for the
  // times of the rest; on each day the first and the last time, searched from
  // the day before, show that it fires that day and on no day between.
  var cursor = utc(windowStart).subtract(oneSecond);
  for (final d in days) {
    expect(
      wall(schedule.nextFrom(cursor)),
      at(d, times.first),
      reason: '$label: first time on $d',
    );
    final endOfDay = utc(d.add(oneDay));
    expect(
      wall(schedule.previousFrom(endOfDay)),
      at(d, times.last),
      reason: '$label: last time on $d',
    );
    cursor = endOfDay.subtract(oneSecond);
  }
  final after = schedule.nextFrom(cursor);
  expect(
    after == null || !after.isBefore(utc(windowEnd)),
    isTrue,
    reason: '$label: fires on $after, after the last day the cron fires',
  );
}

void assertEachOccurrence(
  Schedule schedule,
  List<DateTime> days,
  List<(int, int)> times,
  DateTime end,
  String label,
) {
  final from = utc(windowStart).subtract(oneSecond);
  final to = utc(end).subtract(oneSecond);
  final expected = [
    for (final d in days)
      for (final t in times) at(d, t),
  ];
  final actual = schedule.between(from, to).map(wall).iterator;
  for (final e in expected) {
    final a = actual.moveNext() ? actual.current : null;
    if (a != e) fail('$label: expected $e, got $a');
  }
  if (actual.moveNext()) {
    fail('$label: expected nothing, got ${actual.current}');
  }
}

bool hasEqualGaps(List<(int, int)> times) {
  final minutes = [for (final (h, m) in times) h * 60 + m];
  if (minutes.length < 3) return false;
  for (var i = 1; i < minutes.length; i++) {
    if (minutes[i] - minutes[i - 1] != minutes[1] - minutes[0]) return false;
  }
  return true;
}

/// xorshift32, so the generated cases are the same on every run.
class Rng {
  Rng(this._state);

  int _state;

  T pick<T>(List<T> items) => items[pickIndex(items.length)];

  // Masked so the VM's 64-bit integers and the web's 32-bit bit operations
  // give the same sequence.
  int pickIndex(int length) {
    _state ^= (_state << 13) & 0xFFFFFFFF;
    _state ^= _state >> 17;
    _state ^= (_state << 5) & 0xFFFFFFFF;
    return _state % length;
  }
}

const minuteFields = [
  '0',
  '30',
  '*/15',
  '0-30/10',
  '5,35',
  '*',
  '59',
  '*/7',
  '00',
  '10-50/20',
  '45/5',
  '0/20',
  '1-3',
  '*/99999999999999999999',
  '0,15,30,45',
  '5-10/5',
  '0-59/30',
  '*/20',
];
const hourFields = [
  '9',
  '*',
  '*/2',
  '9-17',
  '9-17/2',
  '0,12',
  '23',
  '0-20/4',
  '*/5',
  '22,0,2',
  '1-23',
  '7/30',
  '009',
  '0-11',
  '*/1',
  '12-12/250',
  '0-16/4',
  '1-21/4',
];
const domFields = [
  '*',
  '1',
  '15',
  '31',
  'L',
  'LW',
  '15W',
  '1-5',
  '1-31/10',
  '?',
  '29',
  '30',
  'lw',
  '1W',
  '31W',
  '*/2',
  '1-31',
  '5-20/3',
  '15,1',
  '02',
  'l',
  '28-31',
  '30W',
  '29w',
  '1-30',
  '2-31',
];
const monthFields = [
  '*',
  '1',
  'JAN',
  '1-3',
  '*/3',
  '2',
  'dec',
  '4',
  'feb',
  '1,7',
  'jun-aug',
  '12,1',
  '*/12',
  '2/5',
  '12-12/250',
  'Sep',
  '2',
  '2',
];
const dowFields = [
  '*',
  '1-5',
  'MON',
  '0',
  '7',
  '5L',
  '1#2',
  'SUN#1',
  '?',
  '1-5/2',
  'sat,sun',
  '0-7',
  '7/2',
  '5-7',
  'fri#5',
  '1#5',
  '0l',
  'mon-fri/2',
  '6,7',
  '7,1',
  '0-6',
  '5/1',
  '*/3',
  'tue-thu',
  '1,1,3',
  '1-4',
  'mon-thu',
  '1-6',
  '0-5',
  '0,6,1',
  'sun,sat',
];

// Two crons in three keep one day field `*`, so most convert; the third draws
// both, so some are rejected for restricting both.
List<String> generatedCrons(int shard) {
  final rng = Rng(0x9e3779b9 + shard);
  return [
    for (var i = 0; i < 150; i++)
      [
        minuteFields,
        hourFields,
        i % 3 == 1 ? const ['*'] : domFields,
        monthFields,
        i % 3 == 0 ? const ['*'] : dowFields,
      ].map(rng.pick).join(' '),
  ];
}

String tooManyTimes(List<(int, int)> times) => hasEqualGaps(times)
    ? intervalDays
    : 'not expressible in hron: ${times.length} times a day are too many to list';

void checkFromCron(int shard) {
  var accepted = 0;
  for (final cron in generatedCrons(shard)) {
    final naive = NaiveCron(cron);
    final times = naive.times();
    if (naive.bothDaysRestricted) {
      expect(fromCronError(cron), bothDays, reason: cron);
      continue;
    }
    final interval = naive.daysCarryAnInterval && hasEqualGaps(times);
    if (times.length > 24 && !interval) {
      expect(fromCronError(cron), tooManyTimes(times), reason: cron);
      continue;
    }
    final schedule = Schedule.fromCron(cron);
    assertFiresAs(schedule, naive, cron);

    final back = schedule.toCron();
    final again = Schedule.fromCron(back);
    final label = '$cron -> $schedule -> $back';
    if (again.toString() != schedule.toString()) {
      assertFiresAs(again, naive, label);
    }
    final naiveBack = NaiveCron(back);
    expect(naiveBack.times(), times, reason: label);
    for (final d in windowDays) {
      expect(naiveBack.firesOn(d), naive.firesOn(d), reason: '$label on $d');
    }
    accepted++;
  }
  expect(accepted, greaterThanOrEqualTo(60), reason: 'crons accepted');
}

const timeLists = [
  '09:00',
  '00:00',
  '23:59',
  '09:00, 17:00',
  '17:00, 09:00, 09:00',
  '00:00, 12:00',
  '09:00, 13:00, 17:00',
  '09:00, 17:30',
  '00:05, 00:35',
  '00:00, 00:01, 00:02, 00:30',
  '00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10',
  '00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59',
  '00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00',
  '09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00, 15:30',
  '09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12, 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24',
];
// Each with the month it names, which a `during` must include.
const dayExpressions = <(String, String?)>[
  ('every day', null),
  ('every weekday', null),
  ('every weekend', null),
  ('every monday', null),
  ('every sunday, saturday', null),
  ('every friday, saturday, sunday', null),
  ('every week on tuesday, friday', null),
  ('every 1 day', null),
  ('every month on the 1st', null),
  ('every month on the 1st to 5th, 20th', null),
  ('every month on the 31st', null),
  ('every month on the 15th, 1st', null),
  ('every month on the 1st to 31st', null),
  ('every month on the last day', null),
  ('every month on the last weekday', null),
  ('every month on the nearest weekday to 1st', null),
  ('every month on the nearest weekday to 31st', null),
  ('every month on the nearest weekday to 15th', null),
  ('every month on the first monday', null),
  ('every month on the fifth friday', null),
  ('every month on the last sunday', null),
  ('every year on feb 29', 'feb'),
  ('every year on dec 25', 'dec'),
  ('every year on the 15th of march', 'mar'),
  ('every year on the first monday of mar', 'mar'),
  ('every year on the fifth monday of feb', 'feb'),
  ('every year on the last friday of feb', 'feb'),
  ('every year on the last weekday of dec', 'dec'),
  ('on feb 14', 'feb'),
  ('on feb 29', 'feb'),
];
const intervals = [
  'every 30 min from 09:00 to 17:30',
  'every 15 min from 00:00 to 23:59',
  'every 2 hours from 00:00 to 23:59',
  'every 7 hours from 00:00 to 23:59',
  'every 45 min from 09:00 to 17:00',
  'every 20 min from 09:00 to 17:40',
  'every 1 minute from 00:00 to 23:59',
  'every 120 min from 01:00 to 23:00',
  'every 2147483647 hours from 00:00 to 23:59',
  'every 5 min from 10:00 to 10:30',
  'every 4 hours from 00:00 to 20:00',
  'every 1 hour from 09:05 to 17:05',
  'every 30 min from 09:00 to 17:00',
];
const intervalDayFilters = [
  '',
  ' on weekday',
  ' on weekend',
  ' on monday, friday',
];
const durings = [
  '',
  '',
  ' during feb',
  ' during dec',
  ' during jan, jul',
  ' during dec, jan, feb',
  ' during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec',
];

typedef GeneratedSchedule = ({
  String hron,
  List<int> times,
  String? ownMonth,
  String during,
});

List<GeneratedSchedule> generatedSchedules() {
  final rng = Rng(0x2545f491);
  return [
    for (var i = 0; i < 240; i++)
      () {
        final during = rng.pick(durings);
        if (i % 3 == 0) {
          final filter = rng.pick(intervalDayFilters);
          final interval = rng.pick(intervals);
          return (
            hron: '$interval$filter$during',
            times: naiveIntervalTimes(interval),
            ownMonth: null,
            during: during,
          );
        }
        final (days, ownMonth) = rng.pick(dayExpressions);
        final times = rng.pick(timeLists);
        return (
          hron: '$days at $times$during',
          times: times.split(', ').map(naiveMinuteOfDay).toList(),
          ownMonth: ownMonth,
          during: during,
        );
      }(),
  ];
}

int naiveMinuteOfDay(String time) {
  final [hour, minute] = time.split(':');
  return int.parse(hour) * 60 + int.parse(minute);
}

List<int> naiveIntervalTimes(String interval) {
  final words = interval.split(' ');
  final every = int.parse(words[1]);
  final step = words[2].startsWith('hour') ? every * 60 : every;
  final from = naiveMinuteOfDay(words[4]);
  final to = naiveMinuteOfDay(words[6]);
  return [
    for (var t = from; t <= to; t++)
      if ((t - from) % step == 0) t,
  ];
}

/// The reason toCron must give, decided from the generated parts alone.
String? expectedToCronFailure(GeneratedSchedule generated) {
  final month = generated.ownMonth;
  if (month != null &&
      generated.during.isNotEmpty &&
      !generated.during.contains(month)) {
    return "during excludes the schedule's month";
  }
  final times = generated.times.toSet();
  final minutes = times.map((t) => t % 60).toSet();
  final hours = times.map((t) => t ~/ 60).toSet();
  return minutes.length * hours.length != times.length
      ? 'times are not every combination of their minutes and hours'
      : null;
}

void main() {
  for (var shard = 0; shard < 4; shard++) {
    test('fromCron is exact, shard $shard', () => checkFromCron(shard));
  }

  test('toCron is exact', () {
    var accepted = 0;
    var rejected = 0;
    for (final generated in generatedSchedules()) {
      final hron = generated.hron;
      final schedule = Schedule.parse(hron);
      final reason = expectedToCronFailure(generated);
      if (reason != null) {
        expect(
          cronMessage(schedule.toCron),
          'not expressible as cron: $reason',
          reason: hron,
        );
        rejected++;
        continue;
      }
      final cron = schedule.toCron();
      final naive = NaiveCron(cron);
      assertFiresAs(schedule, naive, '$hron -> $cron');
      accepted++;

      final times = naive.times();
      final label = '$hron -> $cron -> fromCron';
      final interval = naive.daysCarryAnInterval && hasEqualGaps(times);
      if (times.length > 24 && !interval) {
        expect(fromCronError(cron), tooManyTimes(times), reason: label);
        continue;
      }
      assertFiresAs(Schedule.fromCron(cron), naive, label);
    }
    expect(accepted, greaterThanOrEqualTo(60), reason: 'schedules converted');
    expect(rejected, greaterThanOrEqualTo(20), reason: 'schedules rejected');
  });

  test('values of any length never overflow', () {
    final longZeros = '0' * 10000;
    expect(fromCron('${longZeros}9 ${longZeros}9 * * *'), 'every day at 09:09');
    final huge = '9' * 10000;
    expect(
      fromCronError('0 9 * * 1#$huge'),
      'day of week ordinal must be 1-5, got $huge',
    );
    expect(
      fromCronError('0 9 ${huge}W * *'),
      'day of month must be 1-31, got $huge',
    );
    expect(fromCronError('0 $huge-1 * * *'), 'hour must be 0-23, got $huge');
    expect(fromCron('0 9 * * 1-5/$huge'), 'every monday at 09:00');
    expect(
      fromCronError('0 9 * * */$longZeros'),
      'day of week step must be at least 1',
    );
    expect(fromCron('0 9 * * 0-7/${longZeros}7'), 'every sunday at 09:00');
  });

  test('a long field is parsed in linear time', () {
    final items = List.filled(200000, '1').join(',');
    expect(fromCron('0 9 $items * *'), 'every month on the 1st at 09:00');
    final ranges = List.filled(50000, '0-59/1').join(',');
    expect(fromCron('$ranges 9 * * *'), 'every 1 minute from 09:00 to 09:59');
  });

  test('names and shortcuts fold only ASCII case', () {
    expect(fromCron('@WEEKLY'), 'every sunday at 00:00');
    expect(fromCronError('@weeKly'), 'unknown cron shortcut: @weeKly');
    expect(
      fromCron('0 9 * * SUN-tue'),
      'every sunday, monday, tuesday at 09:00',
    );
    expect(fromCronError('0 9 * * ſun'), 'invalid day of week: ſun');
  });

  test('a 7-minute step converts within an hour and fails across the day', () {
    expect(fromCron('*/7 9 * * *'), 'every 7 min from 09:00 to 09:56');
    expect(
      fromCronError('*/7 * * * *'),
      'not expressible in hron: 216 times a day are too many to list',
    );
  });

  test('fromCron throws only cron errors, and toCron takes what it gives', () {
    const pieces = [
      '0',
      '7',
      '9',
      '59',
      '60',
      '*',
      '/',
      '-',
      ',',
      '#',
      '?',
      'L',
      'w',
      '@',
      ' ',
      '\t',
      '\n',
      'jan',
      'MON',
      'ſun',
      'K',
      '\u00a0',
      '\v',
      '+1',
      '0x1',
      '1e3',
      '99999999999999999999',
      '-1',
      '٣',
    ];
    final rng = Rng(0x1234567);
    for (var i = 0; i < 3000; i++) {
      final cron = [
        for (var n = 0; n < 1 + rng.pickIndex(14); n++) rng.pick(pieces),
      ].join();
      final Schedule schedule;
      try {
        schedule = Schedule.fromCron(cron);
      } on HronError catch (e) {
        expect(e.kind, HronErrorKind.cron, reason: cron);
        continue;
      }
      schedule.toCron();
    }
  });

  test('the naive matcher agrees with known dates', () {
    bool fires(String cron, DateTime d) => NaiveCron(cron).firesOn(d);
    expect(fires('0 9 * 2 1#5', DateTime.utc(2044, 2, 29)), isTrue);
    expect(
      fires('0 9 1W * *', DateTime.utc(2043, 8, 3)),
      isTrue,
      reason: 'Saturday the 1st moves to Monday',
    );
    expect(
      fires('0 9 31W * *', DateTime.utc(2043, 8, 31)),
      isTrue,
      reason: 'Monday the 31st',
    );
    expect(
      fires('0 9 30W * *', DateTime.utc(2044, 4, 29)),
      isTrue,
      reason: 'Saturday the 30th moves to Friday',
    );
    expect(
      fires('0 9 31W * *', DateTime.utc(2044, 7, 29)),
      isTrue,
      reason: 'Sunday the 31st moves to Friday',
    );
    expect(
      fires('0 9 31W * *', DateTime.utc(2044, 4, 30)),
      isFalse,
      reason: 'April has no 31st',
    );
    expect(fires('0 9 LW * *', DateTime.utc(2044, 4, 29)), isTrue);
    expect(fires('0 9 * * 5L', DateTime.utc(2044, 4, 29)), isTrue);
    expect(fires('0 9 * * 5L', DateTime.utc(2044, 4, 22)), isFalse);
  });
}
