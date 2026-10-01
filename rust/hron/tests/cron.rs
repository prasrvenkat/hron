use hron::{Schedule, ScheduleError};
use jiff::civil::{date, Date, Weekday};
use jiff::tz::TimeZone;
use jiff::Zoned;

// Two years around 2044-02-29, a leap day in a February with five Mondays.
const WINDOW_START: Date = date(2043, 6, 1);
const WINDOW_END: Date = date(2045, 6, 1);
// Comparing every occurrence costs a few microseconds each in a debug build.
const FULL_COMPARE_LIMIT: usize = 20_000;

const BOTH_DAYS: &str =
    "not expressible in hron: cron fires on either the day of month or the day of week";
const INTERVAL_DAYS: &str = "not expressible in hron: an interval runs only on every day, weekdays, the weekend or listed days";

fn cron_message<T: std::fmt::Debug>(result: Result<T, ScheduleError>) -> String {
    match result {
        Err(ScheduleError::Cron { message }) => message,
        other => panic!("expected a cron error, got {other:?}"),
    }
}

fn from_cron_error(cron: &str) -> String {
    cron_message(Schedule::from_cron(cron).map(|s| s.to_string()))
}

fn from_cron(cron: &str) -> String {
    Schedule::from_cron(cron)
        .unwrap_or_else(|e| panic!("from_cron({cron:?}): {e}"))
        .to_string()
}

/// A cron matcher written from the cron rules alone, sharing no code with the crate.
/// It expects valid syntax.
struct NaiveCron {
    minutes: Vec<bool>,
    hours: Vec<bool>,
    months: Vec<bool>,
    dom: NaiveDom,
    dow: NaiveDow,
}

enum NaiveDom {
    Any,
    Days(Vec<bool>),
    Last,
    LastWeekday,
    Nearest(u64),
}

enum NaiveDow {
    Any,
    Days(Vec<bool>),
    Nth(u64, u64),
    Last(u64),
}

const MONTH_NAMES: [&str; 13] = [
    "", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const DAY_NAMES: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

impl NaiveCron {
    fn new(cron: &str) -> Self {
        let cron = match cron.trim().to_lowercase().as_str() {
            "@yearly" | "@annually" => "0 0 1 1 *".to_string(),
            "@monthly" => "0 0 1 * *".to_string(),
            "@weekly" => "0 0 * * 0".to_string(),
            "@daily" | "@midnight" => "0 0 * * *".to_string(),
            "@hourly" => "0 * * * *".to_string(),
            other => other.to_string(),
        };
        let f: Vec<&str> = cron.split_whitespace().collect();
        assert_eq!(f.len(), 5, "naive matcher given {cron:?}");
        let dom = match f[2] {
            "*" | "?" => NaiveDom::Any,
            "l" => NaiveDom::Last,
            "lw" => NaiveDom::LastWeekday,
            d if d.ends_with('w') => NaiveDom::Nearest(naive_number(&d[..d.len() - 1], &[])),
            d => NaiveDom::Days(naive_set(d, 1, 31, 31, &[])),
        };
        let dow = match f[4] {
            "*" | "?" => NaiveDow::Any,
            d if d.contains('#') => {
                let (day, nth) = d.split_once('#').unwrap();
                NaiveDow::Nth(naive_number(day, &DAY_NAMES) % 7, naive_number(nth, &[]))
            }
            d if d.ends_with('l') => {
                NaiveDow::Last(naive_number(&d[..d.len() - 1], &DAY_NAMES) % 7)
            }
            d => {
                let mut days = naive_set(d, 0, 7, 6, &DAY_NAMES);
                days[0] |= days[7];
                days.truncate(7);
                NaiveDow::Days(days)
            }
        };
        NaiveCron {
            minutes: naive_set(f[0], 0, 59, 59, &[]),
            hours: naive_set(f[1], 0, 23, 23, &[]),
            months: naive_set(f[3], 1, 12, 12, &MONTH_NAMES),
            dom,
            dow,
        }
    }

    fn times(&self) -> Vec<(i8, i8)> {
        let mut times = Vec::new();
        for hour in 0..24 {
            for minute in 0..60 {
                if self.hours[hour] && self.minutes[minute] {
                    times.push((hour as i8, minute as i8));
                }
            }
        }
        times
    }

    fn fires_on(&self, d: Date) -> bool {
        let day = d.day() as usize;
        let last = d.days_in_month() as usize;
        let weekday = d.weekday().to_sunday_zero_offset() as u64;
        let weekdays: Vec<usize> = (1..=last)
            .filter(|&n| {
                let w = d.with().day(n as i8).build().unwrap().weekday();
                w != Weekday::Saturday && w != Weekday::Sunday
            })
            .collect();
        let dom = match &self.dom {
            NaiveDom::Any => None,
            NaiveDom::Days(set) => Some(set[day]),
            NaiveDom::Last => Some(day == last),
            NaiveDom::LastWeekday => Some(day == *weekdays.last().unwrap()),
            NaiveDom::Nearest(n) => {
                let n = *n as usize;
                let nearest = weekdays.iter().min_by_key(|&&w| w.abs_diff(n)).unwrap();
                Some(n <= last && day == *nearest)
            }
        };
        let dow = match &self.dow {
            NaiveDow::Any => None,
            NaiveDow::Days(set) => Some(set[weekday as usize]),
            NaiveDow::Nth(d, n) => Some(weekday == *d && (day as u64 - 1) / 7 + 1 == *n),
            NaiveDow::Last(d) => Some(weekday == *d && day + 7 > last),
        };
        let day_matches = match (dom, dow) {
            (None, None) => true,
            (Some(a), None) | (None, Some(a)) => a,
            (Some(a), Some(b)) => a || b,
        };
        self.months[d.month() as usize] && day_matches
    }

    fn both_days_restricted(&self) -> bool {
        !matches!(self.dom, NaiveDom::Any) && !matches!(self.dow, NaiveDow::Any)
    }

    fn days_carry_an_interval(&self) -> bool {
        match (&self.dom, &self.dow) {
            (NaiveDom::Any, NaiveDow::Any | NaiveDow::Days(_)) => true,
            (NaiveDom::Days(days), NaiveDow::Any) => days[1..].iter().all(|&d| d),
            _ => false,
        }
    }
}

fn naive_number(text: &str, names: &[&str]) -> u64 {
    match names.iter().position(|name| *name == text) {
        Some(index) => index as u64,
        None => text.parse().unwrap_or(u64::MAX),
    }
}

fn naive_set(field: &str, min: u64, max: u64, star_max: u64, names: &[&str]) -> Vec<bool> {
    let mut set = vec![false; max as usize + 1];
    for item in field.split(',') {
        let (range, step) = match item.split_once('/') {
            Some((range, step)) => (range, Some(naive_number(step, &[]))),
            None => (item, None),
        };
        let (low, high) = if range == "*" {
            (min, star_max)
        } else if let Some((a, b)) = range.split_once('-') {
            (naive_number(a, names), naive_number(b, names))
        } else {
            let a = naive_number(range, names);
            (a, if step.is_some() { a.max(star_max) } else { a })
        };
        let mut value = low;
        while value <= high {
            set[value as usize] = true;
            value = value.saturating_add(step.unwrap_or(1));
        }
    }
    set
}

fn window_days() -> impl Iterator<Item = Date> {
    WINDOW_START
        .series(jiff::Span::new().days(1))
        .take_while(|d| *d < WINDOW_END)
}

fn utc(d: Date, hour: i8, minute: i8) -> Zoned {
    d.at(hour, minute, 0, 0).to_zoned(TimeZone::UTC).unwrap()
}

fn wall(z: &Zoned) -> (Date, (i8, i8)) {
    (z.date(), (z.hour(), z.minute()))
}

fn assert_fires_as(schedule: &Schedule, cron: &NaiveCron, label: &str) {
    let times = cron.times();
    let days: Vec<Date> = window_days().filter(|&d| cron.fires_on(d)).collect();
    if days.len() * times.len() <= FULL_COMPARE_LIMIT {
        assert_each_occurrence(schedule, &days, &times, WINDOW_END, label);
        return;
    }
    let early_end = days[1].tomorrow().unwrap();
    assert_each_occurrence(schedule, &days[..2], &times, early_end, label);
    // Too many to compare one by one. In UTC an hron schedule fires at the same
    // times on every day it fires, so the two days compared in full stand for the
    // times of the rest; on each day the first and the last time, searched from
    // the day before, show that it fires that day and on no day between.
    let mut cursor = utc(WINDOW_START, 0, 0) - jiff::Span::new().seconds(1);
    for &d in &days {
        let next = schedule.next_from(&cursor).map(|z| wall(&z));
        assert_eq!(next, Some((d, times[0])), "{label}: first time on {d}");
        let end_of_day = utc(d.tomorrow().unwrap(), 0, 0);
        let previous = schedule.previous_from(&end_of_day).map(|z| wall(&z));
        assert_eq!(
            previous,
            Some((d, times[times.len() - 1])),
            "{label}: last time on {d}"
        );
        cursor = end_of_day - jiff::Span::new().seconds(1);
    }
    let after = schedule.next_from(&cursor).map(|z| z.date());
    assert!(
        after.is_none_or(|d| d >= WINDOW_END),
        "{label}: fires on {after:?}, after the last day the cron fires"
    );
}

fn assert_each_occurrence(
    schedule: &Schedule,
    days: &[Date],
    times: &[(i8, i8)],
    end: Date,
    label: &str,
) {
    let from = utc(WINDOW_START, 0, 0) - jiff::Span::new().seconds(1);
    let to = utc(end, 0, 0) - jiff::Span::new().seconds(1);
    let mut expected = days
        .iter()
        .flat_map(|&d| times.iter().map(move |&t| (d, t)));
    let mut actual = schedule.between(&from, &to).map(|z| wall(&z));
    loop {
        match (expected.next(), actual.next()) {
            (None, None) => return,
            (e, a) if e == a => continue,
            (e, a) => panic!("{label}: expected {e:?}, got {a:?}"),
        }
    }
}

fn has_equal_gaps(times: &[(i8, i8)]) -> bool {
    let minutes: Vec<i32> = times
        .iter()
        .map(|&(h, m)| i32::from(h) * 60 + i32::from(m))
        .collect();
    minutes.len() >= 3
        && minutes
            .windows(2)
            .all(|w| w[1] - w[0] == minutes[1] - minutes[0])
}

/// xorshift64*, so the generated cases are the same on every run.
struct Rng(u64);

impl Rng {
    fn pick<'a>(&mut self, items: &[&'a str]) -> &'a str {
        items[self.pick_index(items.len())]
    }

    fn pick_index(&mut self, len: usize) -> usize {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        let n = self.0.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 32;
        n as usize % len
    }
}

const MINUTE_FIELDS: &[&str] = &[
    "0",
    "30",
    "*/15",
    "0-30/10",
    "5,35",
    "*",
    "59",
    "*/7",
    "00",
    "10-50/20",
    "45/5",
    "0/20",
    "1-3",
    "*/99999999999999999999",
    "0,15,30,45",
    "5-10/5",
    "0-59/30",
    "*/20",
];
const HOUR_FIELDS: &[&str] = &[
    "9",
    "*",
    "*/2",
    "9-17",
    "9-17/2",
    "0,12",
    "23",
    "0-20/4",
    "*/5",
    "22,0,2",
    "1-23",
    "7/30",
    "009",
    "0-11",
    "*/1",
    "12-12/250",
    "0-16/4",
    "1-21/4",
];
const DOM_FIELDS: &[&str] = &[
    "*", "1", "15", "31", "L", "LW", "15W", "1-5", "1-31/10", "?", "29", "30", "lw", "1W", "31W",
    "*/2", "1-31", "5-20/3", "15,1", "02", "l", "28-31", "30W", "29w", "1-30", "2-31",
];
const MONTH_FIELDS: &[&str] = &[
    "*",
    "1",
    "JAN",
    "1-3",
    "*/3",
    "2",
    "dec",
    "4",
    "feb",
    "1,7",
    "jun-aug",
    "12,1",
    "*/12",
    "2/5",
    "12-12/250",
    "Sep",
    "2",
    "2",
];
const DOW_FIELDS: &[&str] = &[
    "*",
    "1-5",
    "MON",
    "0",
    "7",
    "5L",
    "1#2",
    "SUN#1",
    "?",
    "1-5/2",
    "sat,sun",
    "0-7",
    "7/2",
    "5-7",
    "fri#5",
    "1#5",
    "0l",
    "mon-fri/2",
    "6,7",
    "7,1",
    "0-6",
    "5/1",
    "*/3",
    "tue-thu",
    "1,1,3",
    "1-4",
    "mon-thu",
    "1-6",
    "0-5",
    "0,6,1",
    "sun,sat",
];

// Two crons in three keep one day field `*`, so most convert; the third draws
// both, so some are rejected for restricting both.
fn generated_crons(shard: u64) -> Vec<String> {
    let mut rng = Rng(0x9e37_79b9_7f4a_7c15 ^ shard);
    (0..150)
        .map(|i| {
            let (dom, dow) = match i % 3 {
                0 => (DOM_FIELDS, &["*"][..]),
                1 => (&["*"][..], DOW_FIELDS),
                _ => (DOM_FIELDS, DOW_FIELDS),
            };
            [MINUTE_FIELDS, HOUR_FIELDS, dom, MONTH_FIELDS, dow]
                .map(|field| rng.pick(field))
                .join(" ")
        })
        .collect()
}

fn check_from_cron(shard: u64) {
    let mut accepted = 0;
    for cron in generated_crons(shard) {
        let naive = NaiveCron::new(&cron);
        let times = naive.times();
        let result = Schedule::from_cron(&cron);
        if naive.both_days_restricted() {
            assert_eq!(cron_message(result), BOTH_DAYS, "{cron}");
            continue;
        }
        let interval = naive.days_carry_an_interval() && has_equal_gaps(&times);
        if times.len() > 24 && !interval {
            let expected = if has_equal_gaps(&times) {
                INTERVAL_DAYS.to_string()
            } else {
                format!(
                    "not expressible in hron: {} times a day are too many to list",
                    times.len()
                )
            };
            assert_eq!(cron_message(result), expected, "{cron}");
            continue;
        }
        let schedule = result.unwrap_or_else(|e| panic!("from_cron({cron:?}): {e}"));
        assert_fires_as(&schedule, &naive, &cron);

        let back = schedule
            .to_cron()
            .unwrap_or_else(|e| panic!("to_cron of from_cron({cron:?}) = {schedule}: {e}"));
        let again = Schedule::from_cron(&back)
            .unwrap_or_else(|e| panic!("from_cron({back:?}) from {cron:?}: {e}"));
        let label = format!("{cron} -> {schedule} -> {back}");
        if again != schedule {
            assert_fires_as(&again, &naive, &label);
        }
        let naive_back = NaiveCron::new(&back);
        assert_eq!(naive_back.times(), times, "{label}");
        for d in window_days() {
            assert_eq!(naive_back.fires_on(d), naive.fires_on(d), "{label} on {d}");
        }
        accepted += 1;
    }
    assert!(
        accepted >= 60,
        "only {accepted} generated crons were accepted"
    );
}

#[test]
fn from_cron_is_exact_shard_0() {
    check_from_cron(0);
}

#[test]
fn from_cron_is_exact_shard_1() {
    check_from_cron(1);
}

#[test]
fn from_cron_is_exact_shard_2() {
    check_from_cron(2);
}

#[test]
fn from_cron_is_exact_shard_3() {
    check_from_cron(3);
}

const TIME_LISTS: &[&str] = &[
    "09:00",
    "00:00",
    "23:59",
    "09:00, 17:00",
    "17:00, 09:00, 09:00",
    "00:00, 12:00",
    "09:00, 13:00, 17:00",
    "09:00, 17:30",
    "00:05, 00:35",
    "00:00, 00:01, 00:02, 00:30",
    "00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10",
    "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00, 23:59",
    "00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00",
    "09:00, 09:30, 10:00, 10:30, 11:00, 11:30, 12:00, 12:30, 13:00, 13:30, 14:00, 14:30, 15:00, 15:30",
    "09:00, 09:01, 09:02, 09:03, 09:04, 09:05, 09:06, 09:07, 09:08, 09:09, 09:10, 09:11, 09:12, 09:13, 09:14, 09:15, 09:16, 09:17, 09:18, 09:19, 09:20, 09:21, 09:22, 09:23, 09:24",
];
// Each with the month it names, which a `during` must include.
const DAY_EXPRESSIONS: &[(&str, Option<&str>)] = &[
    ("every day", None),
    ("every weekday", None),
    ("every weekend", None),
    ("every monday", None),
    ("every sunday, saturday", None),
    ("every friday, saturday, sunday", None),
    ("every week on tuesday, friday", None),
    ("every 1 day", None),
    ("every month on the 1st", None),
    ("every month on the 1st to 5th, 20th", None),
    ("every month on the 31st", None),
    ("every month on the 15th, 1st", None),
    ("every month on the 1st to 31st", None),
    ("every month on the last day", None),
    ("every month on the last weekday", None),
    ("every month on the nearest weekday to 1st", None),
    ("every month on the nearest weekday to 31st", None),
    ("every month on the nearest weekday to 15th", None),
    ("every month on the first monday", None),
    ("every month on the fifth friday", None),
    ("every month on the last sunday", None),
    ("every year on feb 29", Some("feb")),
    ("every year on dec 25", Some("dec")),
    ("every year on the 15th of march", Some("mar")),
    ("every year on the first monday of mar", Some("mar")),
    ("every year on the fifth monday of feb", Some("feb")),
    ("every year on the last friday of feb", Some("feb")),
    ("every year on the last weekday of dec", Some("dec")),
    ("on feb 14", Some("feb")),
    ("on feb 29", Some("feb")),
];
const INTERVALS: &[&str] = &[
    "every 30 min from 09:00 to 17:30",
    "every 15 min from 00:00 to 23:59",
    "every 2 hours from 00:00 to 23:59",
    "every 7 hours from 00:00 to 23:59",
    "every 45 min from 09:00 to 17:00",
    "every 20 min from 09:00 to 17:40",
    "every 1 minute from 00:00 to 23:59",
    "every 120 min from 01:00 to 23:00",
    "every 2147483647 hours from 00:00 to 23:59",
    "every 5 min from 10:00 to 10:30",
    "every 4 hours from 00:00 to 20:00",
    "every 1 hour from 09:05 to 17:05",
    "every 30 min from 09:00 to 17:00",
];
const INTERVAL_DAYS_FILTERS: &[&str] = &["", " on weekday", " on weekend", " on monday, friday"];
const DURING: &[&str] = &[
    "",
    "",
    " during feb",
    " during dec",
    " during jan, jul",
    " during dec, jan, feb",
    " during jan, feb, mar, apr, may, jun, jul, aug, sep, oct, nov, dec",
];

struct GeneratedSchedule {
    hron: String,
    times: Vec<u64>,
    own_month: Option<&'static str>,
    during: &'static str,
}

fn generated_schedules() -> Vec<GeneratedSchedule> {
    let mut rng = Rng(0x2545_f491_4f6c_dd1d);
    (0..240)
        .map(|i| {
            let during = rng.pick(DURING);
            if i % 3 == 0 {
                let filter = rng.pick(INTERVAL_DAYS_FILTERS);
                let interval = rng.pick(INTERVALS);
                GeneratedSchedule {
                    hron: format!("{interval}{filter}{during}"),
                    times: naive_interval_times(interval),
                    own_month: None,
                    during,
                }
            } else {
                let (days, own_month) = DAY_EXPRESSIONS[rng.pick_index(DAY_EXPRESSIONS.len())];
                let times = rng.pick(TIME_LISTS);
                GeneratedSchedule {
                    hron: format!("{days} at {times}{during}"),
                    times: times.split(", ").map(naive_minute_of_day).collect(),
                    own_month,
                    during,
                }
            }
        })
        .collect()
}

fn naive_minute_of_day(time: &str) -> u64 {
    let (hour, minute) = time.split_once(':').unwrap();
    hour.parse::<u64>().unwrap() * 60 + minute.parse::<u64>().unwrap()
}

fn naive_interval_times(interval: &str) -> Vec<u64> {
    let words: Vec<&str> = interval.split(' ').collect();
    let every: u64 = words[1].parse().unwrap();
    let step = if words[2].starts_with("hour") {
        every * 60
    } else {
        every
    };
    let (from, to) = (naive_minute_of_day(words[4]), naive_minute_of_day(words[6]));
    (from..=to).filter(|t| (t - from) % step == 0).collect()
}

/// The reason toCron must give, decided from the generated parts alone.
fn expected_to_cron_failure(generated: &GeneratedSchedule) -> Option<&'static str> {
    if let Some(month) = generated.own_month {
        if !generated.during.is_empty() && !generated.during.contains(month) {
            return Some("during excludes the schedule's month");
        }
    }
    let mut times = generated.times.clone();
    times.sort();
    times.dedup();
    let count = |values: Vec<u64>| {
        let mut values = values;
        values.sort();
        values.dedup();
        values.len()
    };
    let minutes = count(times.iter().map(|t| t % 60).collect());
    let hours = count(times.iter().map(|t| t / 60).collect());
    (minutes * hours != times.len())
        .then_some("times are not every combination of their minutes and hours")
}

#[test]
fn to_cron_is_exact() {
    let mut accepted = 0;
    let mut rejected = 0;
    for generated in generated_schedules() {
        let hron = &generated.hron;
        let schedule = Schedule::parse(hron).unwrap_or_else(|e| panic!("parse({hron:?}): {e}"));
        let cron = match (schedule.to_cron(), expected_to_cron_failure(&generated)) {
            (Ok(cron), None) => cron,
            (Err(error), Some(reason)) => {
                assert_eq!(
                    cron_message::<()>(Err(error)),
                    format!("not expressible as cron: {reason}"),
                    "{hron}"
                );
                rejected += 1;
                continue;
            }
            (result, reason) => panic!("{hron}: to_cron gave {result:?}, expected {reason:?}"),
        };
        let naive = NaiveCron::new(&cron);
        assert_fires_as(&schedule, &naive, &format!("{hron} -> {cron}"));
        accepted += 1;

        let times = naive.times();
        let label = format!("{hron} -> {cron} -> from_cron");
        let interval = naive.days_carry_an_interval() && has_equal_gaps(&times);
        if times.len() > 24 && !interval {
            let message = cron_message(Schedule::from_cron(&cron).map(|s| s.to_string()));
            let expected = if has_equal_gaps(&times) {
                INTERVAL_DAYS.to_string()
            } else {
                format!(
                    "not expressible in hron: {} times a day are too many to list",
                    times.len()
                )
            };
            assert_eq!(message, expected, "{label}");
            continue;
        }
        let back = Schedule::from_cron(&cron).unwrap_or_else(|e| panic!("{label}: {e}"));
        assert_fires_as(&back, &naive, &label);
    }
    assert!(
        accepted >= 60 && rejected >= 20,
        "only {accepted} generated schedules converted and {rejected} were rejected"
    );
}

#[test]
fn values_of_any_length_never_overflow() {
    let long_zeros = "0".repeat(10_000);
    assert_eq!(
        from_cron(&format!("{long_zeros}9 {long_zeros}9 * * *")),
        "every day at 09:09"
    );
    let huge = "9".repeat(10_000);
    assert_eq!(
        from_cron_error(&format!("0 9 * * 1#{huge}")),
        format!("day of week ordinal must be 1-5, got {huge}")
    );
    assert_eq!(
        from_cron_error(&format!("0 9 {huge}W * *")),
        format!("day of month must be 1-31, got {huge}")
    );
    assert_eq!(
        from_cron_error(&format!("0 {huge}-1 * * *")),
        format!("hour must be 0-23, got {huge}")
    );
    assert_eq!(
        from_cron(&format!("0 9 * * 1-5/{huge}")),
        "every monday at 09:00"
    );
    assert_eq!(
        from_cron_error(&format!("0 9 * * */{long_zeros}")),
        "day of week step must be at least 1"
    );
    assert_eq!(
        from_cron(&format!("0 9 * * 0-7/{long_zeros}7")),
        "every sunday at 09:00"
    );
}

#[test]
fn a_long_field_is_parsed_in_linear_time() {
    let items = vec!["1"; 200_000].join(",");
    assert_eq!(
        from_cron(&format!("0 9 {items} * *")),
        "every month on the 1st at 09:00"
    );
    let ranges = vec!["0-59/1"; 50_000].join(",");
    assert_eq!(
        from_cron(&format!("{ranges} 9 * * *")),
        "every 1 minute from 09:00 to 09:59"
    );
}

#[test]
fn explain_cron_is_the_converted_schedule() {
    assert_eq!(
        Schedule::explain_cron("*/7 9 * * *").unwrap(),
        "every 7 min from 09:00 to 09:56"
    );
    assert_eq!(
        cron_message(Schedule::explain_cron("*/7 * * * *")),
        "not expressible in hron: 216 times a day are too many to list"
    );
}

#[test]
fn naive_matcher_agrees_with_known_dates() {
    let fires = |cron: &str, d: Date| NaiveCron::new(cron).fires_on(d);
    assert!(fires("0 9 * 2 1#5", date(2044, 2, 29)));
    assert!(
        fires("0 9 1W * *", date(2043, 8, 3)),
        "Saturday the 1st moves to Monday"
    );
    assert!(fires("0 9 31W * *", date(2043, 8, 31)), "Monday the 31st");
    assert!(
        fires("0 9 30W * *", date(2044, 4, 29)),
        "Saturday the 30th moves to Friday"
    );
    assert!(
        fires("0 9 31W * *", date(2044, 7, 29)),
        "Sunday the 31st moves to Friday"
    );
    assert!(
        !fires("0 9 31W * *", date(2044, 4, 30)),
        "April has no 31st"
    );
    assert!(fires("0 9 LW * *", date(2044, 4, 29)));
    assert!(fires("0 9 * * 5L", date(2044, 4, 29)));
    assert!(!fires("0 9 * * 5L", date(2044, 4, 22)));
}
