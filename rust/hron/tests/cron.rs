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

fn to_cron_error(hron: &str) -> String {
    cron_message(Schedule::parse(hron).unwrap().to_cron())
}

fn from_cron(cron: &str) -> String {
    Schedule::from_cron(cron)
        .unwrap_or_else(|e| panic!("from_cron({cron:?}): {e}"))
        .to_string()
}

fn to_cron(hron: &str) -> String {
    Schedule::parse(hron)
        .unwrap()
        .to_cron()
        .unwrap_or_else(|e| panic!("to_cron({hron:?}): {e}"))
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
    // Too many to compare one by one: each firing day's first and last time,
    // found by searching from the day before, also show that no other day fires.
    let mut cursor = utc(WINDOW_START, 0, 0) - jiff::Span::new().seconds(1);
    for &d in &days {
        let next = schedule.next_from(&cursor).unwrap().map(|z| wall(&z));
        assert_eq!(next, Some((d, times[0])), "{label}: first time on {d}");
        let end_of_day = utc(d.tomorrow().unwrap(), 0, 0);
        let previous = schedule
            .previous_from(&end_of_day)
            .unwrap()
            .map(|z| wall(&z));
        assert_eq!(
            previous,
            Some((d, times[times.len() - 1])),
            "{label}: last time on {d}"
        );
        cursor = end_of_day - jiff::Span::new().seconds(1);
    }
    let after = schedule.next_from(&cursor).unwrap().map(|z| z.date());
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
    let mut actual = schedule.between(&from, &to).map(|z| wall(&z.unwrap()));
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
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        let n = self.0.wrapping_mul(0x2545_f491_4f6c_dd1d) >> 32;
        items[n as usize % items.len()]
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

// One day field in three is `*`, the other two restricted, so that most
// generated crons convert and some are rejected for restricting both.
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
const DAY_EXPRESSIONS: &[&str] = &[
    "every day",
    "every weekday",
    "every weekend",
    "every monday",
    "every sunday, saturday",
    "every friday, saturday, sunday",
    "every week on tuesday, friday",
    "every 1 day",
    "every month on the 1st",
    "every month on the 1st to 5th, 20th",
    "every month on the 31st",
    "every month on the 15th, 1st",
    "every month on the 1st to 31st",
    "every month on the last day",
    "every month on the last weekday",
    "every month on the nearest weekday to 1st",
    "every month on the nearest weekday to 31st",
    "every month on the nearest weekday to 15th",
    "every month on the first monday",
    "every month on the fifth friday",
    "every month on the last sunday",
    "every year on feb 29",
    "every year on dec 25",
    "every year on the 15th of march",
    "every year on the first monday of mar",
    "every year on the fifth monday of feb",
    "every year on the last friday of feb",
    "every year on the last weekday of dec",
    "on feb 14",
    "on feb 29",
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

fn generated_schedules() -> Vec<String> {
    let mut rng = Rng(0x2545_f491_4f6c_dd1d);
    (0..240)
        .map(|i| {
            let during = rng.pick(DURING);
            if i % 3 == 0 {
                let filter = rng.pick(INTERVAL_DAYS_FILTERS);
                format!("{}{filter}{during}", rng.pick(INTERVALS))
            } else {
                let days = rng.pick(DAY_EXPRESSIONS);
                format!("{days} at {}{during}", rng.pick(TIME_LISTS))
            }
        })
        .collect()
}

#[test]
fn to_cron_is_exact() {
    let mut accepted = 0;
    for hron in generated_schedules() {
        let schedule = Schedule::parse(&hron).unwrap_or_else(|e| panic!("parse({hron:?}): {e}"));
        let Ok(cron) = schedule.to_cron() else {
            continue;
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
        accepted >= 60,
        "only {accepted} generated schedules converted"
    );
}

#[test]
fn to_cron_keeps_more_than_24_times_that_from_cron_cannot_list() {
    let hron = "every month on the 1st at 00:00, 00:10, 01:00, 01:10, 02:00, 02:10, 03:00, 03:10, 04:00, 04:10, 05:00, 05:10, 06:00, 06:10, 07:00, 07:10, 08:00, 08:10, 09:00, 09:10, 10:00, 10:10, 11:00, 11:10, 12:00, 12:10";
    let cron = to_cron(hron);
    assert_eq!(cron, "0,10 0-12 1 * *");
    assert_eq!(
        from_cron_error(&cron),
        "not expressible in hron: 26 times a day are too many to list"
    );
    let hourly = "every month on the 1st at 00:00, 01:00, 02:00, 03:00, 04:00, 05:00, 06:00, 07:00, 08:00, 09:00, 10:00, 11:00, 12:00, 13:00, 14:00, 15:00, 16:00, 17:00, 18:00, 19:00, 20:00, 21:00, 22:00, 23:00";
    assert_eq!(to_cron(hourly), "0 * 1 * *");
    assert_eq!(from_cron("0 * 1 * *"), hourly);
}

#[test]
fn shortcuts_are_their_crons_in_any_case() {
    for (shortcut, cron) in [
        ("@yearly", "0 0 1 1 *"),
        ("@annually", "0 0 1 1 *"),
        ("@monthly", "0 0 1 * *"),
        ("@weekly", "0 0 * * 0"),
        ("@daily", "0 0 * * *"),
        ("@midnight", "0 0 * * *"),
        ("@hourly", "0 * * * *"),
    ] {
        assert_eq!(from_cron(shortcut), from_cron(cron), "{shortcut}");
        assert_eq!(
            from_cron(&shortcut.to_uppercase()),
            from_cron(cron),
            "{shortcut}"
        );
    }
    assert_eq!(from_cron("\t@HoUrLy\r\n"), from_cron("0 * * * *"));
    assert_eq!(from_cron_error("@ daily"), "unknown cron shortcut: @ daily");
}

#[test]
fn only_spaces_tabs_and_line_ends_are_trimmed_and_only_spaces_and_tabs_separate() {
    assert_eq!(from_cron(" \t\r\n0 \t 9 * *\t*\n\r"), "every day at 09:00");
    assert_eq!(
        from_cron_error("\u{a0}0 9 * * *"),
        "invalid minute: \u{a0}0"
    );
    assert_eq!(
        from_cron_error("0 9 * * *\u{b}"),
        "invalid day of week: *\u{b}"
    );
    assert_eq!(
        from_cron_error("0 9 * *\r*"),
        "expected 5 cron fields, got 4"
    );
}

#[test]
fn names_only_in_month_and_day_of_week_in_ascii_case() {
    assert_eq!(from_cron("0 9 * mAr *"), "every day at 09:00 during mar");
    assert_eq!(from_cron("0 9 * * sAt"), "every saturday at 09:00");
    assert_eq!(from_cron_error("0 jan * * *"), "invalid hour: jan");
    assert_eq!(from_cron_error("0 9 * mon *"), "invalid month: mon");
    assert_eq!(from_cron_error("0 9 * * mar"), "invalid day of week: mar");
    assert_eq!(
        from_cron_error("0 9 * * MONDAY"),
        "invalid day of week: MONDAY"
    );
    assert_eq!(
        from_cron_error("0 9 * * \u{17f}at"),
        "invalid day of week: \u{17f}at"
    );
    assert_eq!(
        from_cron("0 9 * feb-apr/2 *"),
        "every day at 09:00 during feb, apr"
    );
    assert_eq!(
        from_cron("0 9 * * sun-sat/3"),
        "every sunday, wednesday, saturday at 09:00"
    );
}

#[test]
fn name_is_not_a_step() {
    assert_eq!(from_cron_error("0 9 * */jan *"), "invalid month: */jan");
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
fn huge_step_on_a_one_value_range_selects_the_start() {
    assert_eq!(
        from_cron("0 9 * 12-12/250 *"),
        "every day at 09:00 during dec"
    );
    assert_eq!(
        from_cron("0 9 31-31/99 * *"),
        "every month on the 31st at 09:00"
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
fn star_and_open_steps_cover_sunday_once_and_7_is_sunday_where_written() {
    assert_eq!(from_cron("0 9 * * 7/2"), "every sunday at 09:00");
    assert_eq!(from_cron("0 9 * * 7/1"), "every sunday at 09:00");
    assert_eq!(from_cron("0 9 * * 5/1"), "every friday, saturday at 09:00");
    assert_eq!(from_cron("0 9 * * 6/2"), "every saturday at 09:00");
    assert_eq!(
        from_cron("0 9 * * 0/3"),
        "every sunday, wednesday, saturday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * */3"),
        "every sunday, wednesday, saturday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * 1-7/3"),
        "every monday, thursday, sunday at 09:00"
    );
    assert_eq!(from_cron("0 9 * * 0-7/7"), "every sunday at 09:00");
    assert_eq!(from_cron("0 9 * * 7-7"), "every sunday at 09:00");
    assert_eq!(
        from_cron("0 9 * * 7L"),
        "every month on the last sunday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * 7l"),
        "every month on the last sunday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * friL"),
        "every month on the last friday at 09:00"
    );
}

#[test]
fn open_steps_run_to_the_field_maximum() {
    assert_eq!(from_cron("50/5 9 * * *"), "every day at 09:50, 09:55");
    assert_eq!(from_cron("0 20/2 * * *"), "every day at 20:00, 22:00");
    assert_eq!(
        from_cron("0 9 28/2 * *"),
        "every month on the 28th, 30th at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * 10/2 *"),
        "every day at 09:00 during oct, dec"
    );
}

#[test]
fn a_step_larger_than_its_range_selects_only_the_start() {
    assert_eq!(from_cron("5-10/60 9 * * *"), "every day at 09:05");
    assert_eq!(from_cron("0 9 * */13 *"), "every day at 09:00 during jan");
    assert_eq!(from_cron("0 9 * * 2/7"), "every tuesday at 09:00");
}

#[test]
fn only_exactly_star_or_question_mark_leaves_a_day_field_unrestricted() {
    assert_eq!(from_cron_error("0 9 *,1 * 1"), BOTH_DAYS);
    assert_eq!(from_cron_error("0 9 1 * *,1"), BOTH_DAYS);
    assert_eq!(from_cron_error("0 9 L * ?/1"), "invalid day of week: ?/1");
    assert_eq!(from_cron("0 9 ? * ?"), "every day at 09:00");
    assert_eq!(from_cron("0 9 *,1 * *"), "every day at 09:00");
}

#[test]
fn letter_forms_take_any_case_and_are_the_whole_field() {
    assert_eq!(
        from_cron("0 9 Lw * *"),
        "every month on the last weekday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 lW * *"),
        "every month on the last weekday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 015w * *"),
        "every month on the nearest weekday to 15th at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * Fri#01"),
        "every month on the first friday at 09:00"
    );
    for (field, cron) in [
        ("day of month", "0 9 L,1 * *"),
        ("day of month", "0 9 LW-1 * *"),
        ("day of month", "0 9 W * *"),
        ("day of month", "0 9 1-5W * *"),
        ("day of month", "0 9 L/2 * *"),
        ("day of month", "0 9 1L * *"),
        ("day of month", "0 9 15W,1 * *"),
        ("day of week", "0 9 * * 1#1/2"),
        ("day of week", "0 9 * * 1-2#1"),
        ("day of week", "0 9 * * #1"),
        ("day of week", "0 9 * * 1#-1"),
        ("day of week", "0 9 * * 1L,2"),
        ("day of week", "0 9 * * 1-5L"),
        ("day of week", "0 9 * * LW"),
        ("day of week", "0 9 * * 1W"),
        ("minute", "L 9 * * *"),
        ("hour", "0 1#1 * * *"),
        ("month", "0 9 * L *"),
    ] {
        let text = cron
            .split(' ')
            .find(|f| f.contains(['L', 'W', '#']))
            .unwrap();
        assert_eq!(
            from_cron_error(cron),
            format!("invalid {field}: {text}"),
            "{cron}"
        );
    }
}

#[test]
fn value_errors_echo_the_value_as_written() {
    assert_eq!(
        from_cron_error("0 9 * * 08"),
        "day of week must be 0-7, got 08"
    );
    assert_eq!(
        from_cron_error("0 9 * 013 *"),
        "month must be 1-12, got 013"
    );
    assert_eq!(
        from_cron_error("0 9 00 * *"),
        "day of month must be 1-31, got 00"
    );
    assert_eq!(
        from_cron_error("0 9 0W * *"),
        "day of month must be 1-31, got 0"
    );
    assert_eq!(
        from_cron_error("0 9 32W * *"),
        "day of month must be 1-31, got 32"
    );
    assert_eq!(
        from_cron_error("0 9 * * 8L"),
        "day of week must be 0-7, got 8"
    );
    assert_eq!(
        from_cron_error("0 9 * * 9#1"),
        "day of week must be 0-7, got 9"
    );
    assert_eq!(
        from_cron_error("0 9 * * 1#0"),
        "day of week ordinal must be 1-5, got 0"
    );
    assert_eq!(
        from_cron_error("0 9 * * 1#00"),
        "day of week ordinal must be 1-5, got 00"
    );
    assert_eq!(from_cron_error("0 9 1 * 1-7"), BOTH_DAYS);
    assert_eq!(
        from_cron_error("0 9 * MAR-jan *"),
        "month range must not run backwards: MAR-jan"
    );
    assert_eq!(
        from_cron_error("0 9 * * */00"),
        "day of week step must be at least 1"
    );
    assert_eq!(
        from_cron_error("0 */0 * * *"),
        "hour step must be at least 1"
    );
    assert_eq!(
        from_cron_error("0 9 1/0 * *"),
        "day of month step must be at least 1"
    );
}

#[test]
fn the_shortcut_is_checked_before_the_field_count() {
    assert_eq!(
        from_cron_error("@daily 0 9"),
        "unknown cron shortcut: @daily 0 9"
    );
}

#[test]
fn the_field_count_is_checked_before_any_field() {
    assert_eq!(from_cron_error("x y z"), "expected 5 cron fields, got 3");
}

#[test]
fn each_field_is_checked_whole_before_the_next() {
    assert_eq!(from_cron_error("60 x * * *"), "minute must be 0-59, got 60");
    assert_eq!(from_cron_error("x 24 * * *"), "invalid minute: x");
    assert_eq!(from_cron_error("0 24 32 * *"), "hour must be 0-23, got 24");
    assert_eq!(
        from_cron_error("0 9 32 13 8"),
        "day of month must be 1-31, got 32"
    );
    assert_eq!(from_cron_error("0 9 1 13 8"), "month must be 1-12, got 13");
    assert_eq!(
        from_cron_error("0 9 * 1 8"),
        "day of week must be 0-7, got 8"
    );
}

#[test]
fn a_fields_syntax_is_checked_before_its_items() {
    assert_eq!(from_cron_error("60,x 9 * * *"), "invalid minute: 60,x");
    assert_eq!(from_cron_error("5-1,x 9 * * *"), "invalid minute: 5-1,x");
}

#[test]
fn items_are_checked_from_left_to_right() {
    assert_eq!(
        from_cron_error("5-1,60 9 * * *"),
        "minute range must not run backwards: 5-1"
    );
    assert_eq!(
        from_cron_error("*/0,60 9 * * *"),
        "minute step must be at least 1"
    );
    assert_eq!(
        from_cron_error("60,5-1 9 * * *"),
        "minute must be 0-59, got 60"
    );
}

#[test]
fn an_items_values_come_before_its_direction_then_step_then_ordinal() {
    assert_eq!(
        from_cron_error("0 9 * * 8-1/0"),
        "day of week must be 0-7, got 8"
    );
    assert_eq!(
        from_cron_error("0 9 * * 1-8/0"),
        "day of week must be 0-7, got 8"
    );
    assert_eq!(
        from_cron_error("0 9 * * 5-1/0"),
        "day of week range must not run backwards: 5-1"
    );
    assert_eq!(
        from_cron_error("0 9 * * 8#0"),
        "day of week must be 0-7, got 8"
    );
}

#[test]
fn the_fields_come_before_both_day_fields_which_come_before_the_times() {
    assert_eq!(from_cron_error("0 9 15 13 1"), "month must be 1-12, got 13");
    assert_eq!(
        from_cron_error("0 9 15 * 1#6"),
        "day of week ordinal must be 1-5, got 6"
    );
    assert_eq!(from_cron_error("*/7 * 15 * 1"), BOTH_DAYS);
}

#[test]
fn twenty_four_times_are_listed_and_twenty_five_are_not() {
    assert_eq!(
        from_cron("0-23 9 1 * *"),
        format!(
            "every month on the 1st at {}",
            (0..24)
                .map(|m| format!("09:{m:02}"))
                .collect::<Vec<_>>()
                .join(", ")
        )
    );
    assert_eq!(from_cron_error("0-24 9 1 * *"), INTERVAL_DAYS);
    assert_eq!(from_cron_error("0-24 9 L * *"), INTERVAL_DAYS);
    assert_eq!(from_cron_error("0-24 9 * * 1#1"), INTERVAL_DAYS);
    assert_eq!(
        from_cron_error("0-4 0-3,5 * * *"),
        "not expressible in hron: 25 times a day are too many to list"
    );
    assert_eq!(
        from_cron("0-3 0-5 * * *").matches(", ").count() + 1,
        24,
        "24 times with unequal gaps are listed"
    );
}

#[test]
fn equal_gaps_on_listable_days_are_an_interval_from_three_times() {
    assert_eq!(from_cron("0,30 9 * * *"), "every day at 09:00, 09:30");
    assert_eq!(
        from_cron("0,20,40 9 * * *"),
        "every 20 min from 09:00 to 09:40"
    );
    assert_eq!(
        from_cron("0 9,11,13 * * 1"),
        "every 2 hours from 09:00 to 13:00 on monday"
    );
    assert_eq!(
        from_cron("0 */4 1-31 * *"),
        "every 4 hours from 00:00 to 23:59"
    );
    assert_eq!(
        from_cron("0 9,13,17 1 * *"),
        "every month on the 1st at 09:00, 13:00, 17:00"
    );
    assert_eq!(
        from_cron("0 9,13,17 * * 5L"),
        "every month on the last friday at 09:00, 13:00, 17:00"
    );
    assert_eq!(
        from_cron("0 9,13,17 L * *"),
        "every month on the last day at 09:00, 13:00, 17:00"
    );
    assert_eq!(
        from_cron("0 9,13,17 25 12 *"),
        "every year on dec 25 at 09:00, 13:00, 17:00"
    );
    assert_eq!(
        from_cron("0 */2 * * 6,7"),
        "every 2 hours from 00:00 to 23:59 on weekend"
    );
    assert_eq!(
        from_cron("30 */2 * * 0-7"),
        "every 2 hours from 00:30 to 22:30"
    );
    assert_eq!(from_cron("0,30 0-23/2 * * *"), "every day at 00:00, 00:30, 02:00, 02:30, 04:00, 04:30, 06:00, 06:30, 08:00, 08:30, 10:00, 10:30, 12:00, 12:30, 14:00, 14:30, 16:00, 16:30, 18:00, 18:30, 20:00, 20:30, 22:00, 22:30");
}

#[test]
fn an_interval_from_midnight_ends_at_2359_only_when_the_next_time_reaches_midnight() {
    assert_eq!(
        from_cron("0 0-20/4 * * *"),
        "every 4 hours from 00:00 to 23:59"
    );
    assert_eq!(
        from_cron("0 0-16/4 * * *"),
        "every 4 hours from 00:00 to 16:00"
    );
    assert_eq!(
        from_cron("0 */5 * * *"),
        "every 5 hours from 00:00 to 23:59"
    );
    assert_eq!(
        from_cron("0 1-21/4 * * *"),
        "every 4 hours from 01:00 to 21:00"
    );
    assert_eq!(
        from_cron("*/20 0-22 * * *"),
        "every 20 min from 00:00 to 22:40"
    );
    assert_eq!(
        from_cron("*/20 0-23 * * *"),
        "every 20 min from 00:00 to 23:59"
    );
    assert_eq!(
        from_cron("59 0-23 * * *"),
        "every 1 hour from 00:59 to 23:59"
    );
    assert_eq!(from_cron("0 0,12 * * 1"), "every monday at 00:00, 12:00");
}

#[test]
fn intervals_of_whole_hours_are_written_in_hours() {
    assert_eq!(
        from_cron("0 9-17/3 * * *"),
        "every 3 hours from 09:00 to 15:00"
    );
    assert_eq!(from_cron("0 * * * *"), "every 1 hour from 00:00 to 23:59");
    assert_eq!(from_cron("15 */12 * * *"), "every day at 00:15, 12:15");
    assert_eq!(
        from_cron("*/30 9-10 * * *"),
        "every 30 min from 09:00 to 10:30"
    );
}

#[test]
fn day_of_week_lists_keep_first_appearance_without_repeats() {
    assert_eq!(
        from_cron("0 9 * * 5-7,1"),
        "every friday, saturday, sunday, monday at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * * 3,0,7,3"),
        "every wednesday, sunday at 09:00"
    );
    assert_eq!(from_cron("0 9 * * 6,0-5"), "every day at 09:00");
    assert_eq!(from_cron("0 9 * * 5,1-4"), "every weekday at 09:00");
    assert_eq!(from_cron("0 9 * * 7,6"), "every weekend at 09:00");
    assert_eq!(
        from_cron("*/30 9-10 * * 5,2"),
        "every 30 min from 09:00 to 10:30 on friday, tuesday"
    );
}

#[test]
fn days_of_month_ascend_with_runs_of_two_or_more() {
    assert_eq!(
        from_cron("0 9 31,1,2,3,10,12,11 * *"),
        "every month on the 1st to 3rd, 10th to 12th, 31st at 09:00"
    );
    assert_eq!(
        from_cron("0 9 1-30 * *"),
        "every month on the 1st to 30th at 09:00"
    );
    assert_eq!(from_cron("0 9 1-15,16-31 * *"), "every day at 09:00");
}

#[test]
fn months_add_during_in_ascending_order_unless_all_twelve() {
    assert_eq!(
        from_cron("0 9 * dec,jan,6 *"),
        "every day at 09:00 during jan, jun, dec"
    );
    assert_eq!(from_cron("0 9 * 1-6,7-12 *"), "every day at 09:00");
    assert_eq!(
        from_cron("0 9 L 1,2 *"),
        "every month on the last day at 09:00 during jan, feb"
    );
}

#[test]
fn one_month_with_one_day_it_has_is_yearly() {
    assert_eq!(from_cron("0 9 29 feb *"), "every year on feb 29 at 09:00");
    assert_eq!(
        from_cron("0 9 30 2 *"),
        "every month on the 30th at 09:00 during feb"
    );
    assert_eq!(from_cron("0 9 30 4 *"), "every year on apr 30 at 09:00");
    assert_eq!(
        from_cron("0 9 31 4 *"),
        "every month on the 31st at 09:00 during apr"
    );
    assert_eq!(from_cron("0 9 31 3 *"), "every year on mar 31 at 09:00");
    assert_eq!(
        from_cron("0 9 * 2 1#5"),
        "every year on the fifth monday of feb at 09:00"
    );
    assert_eq!(
        from_cron("0 9 * 2 0L"),
        "every year on the last sunday of feb at 09:00"
    );
    assert_eq!(
        from_cron("0 9 LW 2 *"),
        "every year on the last weekday of feb at 09:00"
    );
    assert_eq!(
        from_cron("0 9 L 2 *"),
        "every month on the last day at 09:00 during feb"
    );
    assert_eq!(
        from_cron("0 9 29W 2 *"),
        "every month on the nearest weekday to 29th at 09:00 during feb"
    );
    assert_eq!(from_cron("0 9 1-31 2 *"), "every day at 09:00 during feb");
    assert_eq!(from_cron("0 9 * 2 1"), "every monday at 09:00 during feb");
}

#[test]
fn to_cron_reports_the_first_reason_in_order() {
    let reasons = [
        (
            "every 2 days at 09:00 except dec 25 until 2027-01-01 starting 2026-01-01",
            "except clauses not supported",
        ),
        (
            "every 2 days at 09:00 until 2027-01-01 starting 2026-01-01",
            "until clauses not supported",
        ),
        (
            "every 2 days at 09:00, 17:30 starting 2026-01-01",
            "starting clauses not supported",
        ),
        (
            "on 2026-03-15 at 09:00, 17:30 during jan",
            "ISO dates do not repeat",
        ),
        (
            "every 2 days at 09:00, 17:30 during jan",
            "multi-day repeats not supported",
        ),
        (
            "every 2 weeks on monday at 09:00, 17:30",
            "multi-week repeats not supported",
        ),
        (
            "every 2 months on the previous nearest weekday to 1st at 09:00, 17:30",
            "multi-month repeats not supported",
        ),
        (
            "every 2 years on dec 25 at 09:00, 17:30 during jan",
            "multi-year repeats not supported",
        ),
        (
            "every month on the next nearest weekday to 1st at 09:00, 17:30",
            "directional nearest weekday not supported",
        ),
        (
            "every year on the last weekday of dec at 09:00, 17:30 during jan",
            "during excludes the schedule's month",
        ),
        (
            "every month on the 1st at 09:00, 17:30 during jan",
            "times are not every combination of their minutes and hours",
        ),
    ];
    for (hron, reason) in reasons {
        assert_eq!(
            to_cron_error(hron),
            format!("not expressible as cron: {reason}"),
            "{hron}"
        );
    }
}

#[test]
fn to_cron_writes_minutes_and_hours_by_the_first_rule_that_fits() {
    assert_eq!(to_cron("every 1 minute from 00:00 to 23:59"), "* * * * *");
    assert_eq!(to_cron("every day at 07:42"), "42 7 * * *");
    assert_eq!(to_cron("every 20 min from 00:00 to 23:59"), "*/20 * * * *");
    assert_eq!(to_cron("every 6 hours from 00:00 to 23:59"), "0 */6 * * *");
    assert_eq!(to_cron("every 7 min from 00:00 to 00:56"), "0-56/7 0 * * *");
    assert_eq!(to_cron("every day at 00:00, 00:01"), "0-1 0 * * *");
    assert_eq!(
        to_cron("every day at 00:00, 00:30, 01:00, 01:30"),
        "*/30 0-1 * * *"
    );
    assert_eq!(to_cron("every day at 00:10, 00:40"), "10,40 0 * * *");
    assert_eq!(to_cron("every day at 00:00, 00:20"), "0,20 0 * * *");
    assert_eq!(to_cron("every day at 00:00, 00:20, 00:40"), "*/20 0 * * *");
    assert_eq!(to_cron("every day at 00:20, 00:40"), "20,40 0 * * *");
    assert_eq!(
        to_cron("every day at 00:05, 00:25, 00:45"),
        "5-45/20 0 * * *"
    );
    assert_eq!(to_cron("every day at 01:00, 13:00"), "0 1,13 * * *");
    assert_eq!(to_cron("every day at 00:00, 08:00, 16:00"), "0 */8 * * *");
    assert_eq!(to_cron("every day at 00:00, 08:00"), "0 0,8 * * *");
    assert_eq!(
        to_cron("every day at 00:00, 01:00, 03:00, 04:00, 05:00, 09:00"),
        "0 0-1,3-5,9 * * *"
    );
    assert_eq!(to_cron("every 1 hour from 00:00 to 22:00"), "0 0-22 * * *");
}

#[test]
fn to_cron_writes_day_and_month_fields_as_lists_with_sunday_as_0() {
    assert_eq!(to_cron("every sunday, monday at 09:00"), "0 9 * * 0-1");
    assert_eq!(
        to_cron("every monday, wednesday, thursday, friday at 09:00"),
        "0 9 * * 1,3-5"
    );
    assert_eq!(
        to_cron("every month on the 1st, 3rd, 5th at 09:00"),
        "0 9 1,3,5 * *"
    );
    assert_eq!(
        to_cron("every month on the 5th to 7th, 6th to 9th at 09:00"),
        "0 9 5-9 * *"
    );
    assert_eq!(
        to_cron("every day at 09:00 during jan, mar, may"),
        "0 9 * 1,3,5 *"
    );
    assert_eq!(
        to_cron("every month on the last sunday at 09:00"),
        "0 9 * * 0L"
    );
    assert_eq!(
        to_cron("every month on the fifth sunday at 09:00"),
        "0 9 * * 0#5"
    );
    assert_eq!(
        to_cron("every month on the nearest weekday to 1st at 09:00 during feb"),
        "0 9 1W 2 *"
    );
    assert_eq!(
        to_cron("every 15 min from 09:00 to 09:45 on sunday, saturday, monday"),
        "*/15 9 * * 0-1,6"
    );
}

#[test]
fn yearly_and_named_dates_write_their_own_month() {
    assert_eq!(
        to_cron("every year on mar 1 at 09:00 during jan, mar"),
        "0 9 1 3 *"
    );
    assert_eq!(to_cron("on dec 31 at 23:59 during dec"), "59 23 31 12 *");
    assert_eq!(
        to_cron("every year on the first monday of mar at 09:00 during mar"),
        "0 9 * 3 1#1"
    );
    assert_eq!(
        to_cron("every year on the last weekday of jun at 09:00"),
        "0 9 LW 6 *"
    );
    assert_eq!(
        to_cron("every year on the 15th of march at 09:00"),
        "0 9 15 3 *"
    );
}

#[test]
fn to_cron_drops_the_timezone() {
    assert_eq!(
        to_cron("every weekday at 09:00 in Asia/Kolkata"),
        "0 9 * * 1-5"
    );
}

#[test]
fn huge_intervals_do_not_overflow() {
    assert_eq!(
        to_cron("every 2147483647 hours from 00:00 to 23:59"),
        "0 0 * * *"
    );
    assert_eq!(
        to_cron("every 2147483647 min from 09:00 to 23:59"),
        "0 9 * * *"
    );
    assert_eq!(to_cron("every 1440 min from 00:00 to 23:59"), "0 0 * * *");
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

#[test]
fn to_cron_of_a_built_schedule_with_interval_0_steps_by_1_as_evaluation_does() {
    use hron::ast::{IntervalUnit, ScheduleExpr, TimeOfDay};
    let schedule = Schedule::new(ScheduleExpr::IntervalRepeat {
        interval: 0,
        unit: IntervalUnit::Minutes,
        from: TimeOfDay { hour: 9, minute: 0 },
        to: TimeOfDay { hour: 9, minute: 2 },
        day_filter: None,
    });
    assert_eq!(schedule.to_cron().unwrap(), "0-2 9 * * *");
    let from = utc(WINDOW_START, 9, 0);
    let fires: Vec<_> = schedule
        .next_n_from(&from, 2)
        .unwrap()
        .iter()
        .map(wall)
        .collect();
    assert_eq!(fires, [(WINDOW_START, (9, 1)), (WINDOW_START, (9, 2))]);
}

#[test]
fn to_cron_of_a_built_schedule_without_times_fails() {
    use hron::ast::{DayFilter, ScheduleExpr};
    let schedule = Schedule::new(ScheduleExpr::DayRepeat {
        interval: 1,
        days: DayFilter::Every,
        times: vec![],
    });
    assert_eq!(
        cron_message(schedule.to_cron()),
        "not expressible as cron: times are not every combination of their minutes and hours"
    );
}
