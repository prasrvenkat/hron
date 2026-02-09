use criterion::{black_box, criterion_group, criterion_main, Criterion};
use hron::Schedule;

fn fixed_now() -> jiff::Zoned {
    jiff::civil::Date::new(2026, 2, 6)
        .unwrap()
        .to_datetime(jiff::civil::Time::new(12, 0, 0, 0).unwrap())
        .to_zoned(jiff::tz::TimeZone::UTC)
        .unwrap()
}

// ---------------------------------------------------------------------------
// Parse benchmarks
// ---------------------------------------------------------------------------

fn bench_parse(c: &mut Criterion) {
    let mut group = c.benchmark_group("parse");

    group.bench_function("simple", |b| {
        b.iter(|| Schedule::parse(black_box("every day at 09:00")).unwrap());
    });

    group.bench_function("complex", |b| {
        b.iter(|| {
            Schedule::parse(black_box(
                "every 2 weeks on mon, wed at 09:00, 14:00 except dec 25 until 2027-12-31 in America/New_York",
            ))
            .unwrap()
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Eval benchmarks (next_from)
// ---------------------------------------------------------------------------

fn bench_eval(c: &mut Criterion) {
    let mut group = c.benchmark_group("eval");
    let now = fixed_now();

    // DayRepeat
    let day_repeat = Schedule::parse("every weekday at 09:00 in UTC").unwrap();
    group.bench_function("day_repeat", |b| {
        b.iter(|| day_repeat.next_from(black_box(&now)).unwrap());
    });

    // WeekRepeat
    let week_repeat =
        Schedule::parse("every 2 weeks on monday at 09:00 starting 2026-01-05 in UTC").unwrap();
    group.bench_function("week_repeat", |b| {
        b.iter(|| week_repeat.next_from(black_box(&now)).unwrap());
    });

    // MonthRepeat
    let month_repeat = Schedule::parse("every month on the 1st at 09:00 in UTC").unwrap();
    group.bench_function("month_repeat", |b| {
        b.iter(|| month_repeat.next_from(black_box(&now)).unwrap());
    });

    // OrdinalRepeat
    let ordinal_repeat =
        Schedule::parse("first monday of every month at 10:00 in UTC").unwrap();
    group.bench_function("ordinal_repeat", |b| {
        b.iter(|| ordinal_repeat.next_from(black_box(&now)).unwrap());
    });

    // YearRepeat
    let year_repeat = Schedule::parse("every year on dec 25 at 00:00 in UTC").unwrap();
    group.bench_function("year_repeat", |b| {
        b.iter(|| year_repeat.next_from(black_box(&now)).unwrap());
    });

    // IntervalRepeat
    let interval_repeat =
        Schedule::parse("every 30 min from 09:00 to 17:00 in UTC").unwrap();
    group.bench_function("interval_repeat", |b| {
        b.iter(|| interval_repeat.next_from(black_box(&now)).unwrap());
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Display benchmark (parse + to_string roundtrip)
// ---------------------------------------------------------------------------

fn bench_display(c: &mut Criterion) {
    let mut group = c.benchmark_group("display");

    let schedule = Schedule::parse(
        "every 2 weeks on mon, wed at 09:00, 14:00 except dec 25 until 2027-12-31 in America/New_York",
    )
    .unwrap();

    group.bench_function("to_string_roundtrip", |b| {
        b.iter(|| black_box(&schedule).to_string());
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Cron benchmarks
// ---------------------------------------------------------------------------

fn bench_cron(c: &mut Criterion) {
    let mut group = c.benchmark_group("cron");

    // to_cron
    let schedule = Schedule::parse("every weekday at 09:00").unwrap();
    group.bench_function("to_cron", |b| {
        b.iter(|| black_box(&schedule).to_cron().unwrap());
    });

    // from_cron
    group.bench_function("from_cron", |b| {
        b.iter(|| Schedule::from_cron(black_box("0 9 * * 1-5")).unwrap());
    });

    group.finish();
}

criterion_group!(benches, bench_parse, bench_eval, bench_display, bench_cron);
criterion_main!(benches);
