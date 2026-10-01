//! Wall-clock times on dates in a time zone. A wall time a fall-back repeats
//! takes its first pass (spec/README.md, "DST fall-back (ambiguous times)").

use jiff::civil::{Date, Time};
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::Zoned;

use crate::ast::TimeOfDay;

pub(super) const MINUTES_PER_HOUR: i64 = 60;

/// The instant `time` names on `date`, shifted forward by the gap's length when
/// it falls in a spring-forward gap (spec/README.md, "DST spring-forward
/// (gaps)"): jiff's "compatible" disambiguation. None beyond what jiff can
/// represent, which is outside the supported range.
pub(super) fn fixed_time_on(date: Date, time: Time, zone: &TimeZone) -> Option<Zoned> {
    date.to_datetime(time).to_zoned(zone.clone()).ok()
}

/// The instant of the interval slot `minute` minutes after midnight on `date`,
/// or None when that wall time falls in a spring-forward gap (spec/README.md,
/// "Interval slots in a spring-forward gap").
pub(super) fn slot_on(date: Date, minute: i64, zone: &TimeZone) -> Option<Zoned> {
    let time = Time::new(
        (minute / MINUTES_PER_HOUR) as i8,
        (minute % MINUTES_PER_HOUR) as i8,
        0,
        0,
    )
    .unwrap();
    let ambiguous = zone.to_ambiguous_zoned(date.to_datetime(time));
    if matches!(ambiguous.offset(), AmbiguousOffset::Gap { .. }) {
        return None;
    }
    ambiguous.earlier().ok()
}

pub(super) fn civil_time(time: &TimeOfDay) -> Time {
    Time::new(time.hour as i8, time.minute as i8, 0, 0).unwrap()
}

pub(super) fn minute_of_day(time: Time) -> i64 {
    time.hour() as i64 * MINUTES_PER_HOUR + time.minute() as i64
}
