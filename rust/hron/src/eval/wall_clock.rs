//! A wall time a fall-back repeats takes its first pass (spec/README.md,
//! "DST fall-back (ambiguous times)").

use jiff::civil::{Date, Time};
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::{Span, Timestamp, Zoned};

use crate::ast::TimeOfDay;

pub(super) const MINUTES_PER_HOUR: i64 = 60;

/// The instant `time` names on `date`, shifted forward by the gap's length when
/// it falls in a spring-forward gap (spec/README.md, "DST spring-forward
/// (gaps)"): jiff's "compatible" disambiguation. None beyond what jiff can
/// represent, which is outside the supported range.
pub(super) fn fixed_time_on(date: Date, time: Time, zone: &TimeZone) -> Option<Zoned> {
    date.to_datetime(time).to_zoned(zone.clone()).ok()
}

/// An interval slot on a date: where it sits in time, and its instant unless a
/// spring-forward gap skips it (spec/README.md, "Interval slots in a
/// spring-forward gap"). A skipped slot sits at the instant its gap ends, so
/// keys never decrease in wall-clock order and one binary search finds the
/// slots on either side of an instant.
pub(super) struct Slot {
    pub(super) key: Timestamp,
    pub(super) instant: Option<Zoned>,
}

/// The slot `minute` minutes after midnight on `date`. Past what jiff can
/// represent, which is outside the supported range, it sits at the end of time;
/// so does a gap slot whose gap end cannot be found.
pub(super) fn slot_on(date: Date, minute: i64, zone: &TimeZone) -> Slot {
    let time = Time::new(
        (minute / MINUTES_PER_HOUR) as i8,
        (minute % MINUTES_PER_HOUR) as i8,
        0,
        0,
    )
    .unwrap();
    let wall = date.to_datetime(time);
    let ambiguous = zone.to_ambiguous_zoned(wall);
    if let AmbiguousOffset::Gap { before, .. } = ambiguous.offset() {
        let gap_end = before.to_timestamp(wall).ok().and_then(|in_gap| {
            let transitions = zone.preceding(in_gap.checked_add(Span::new().nanoseconds(1)).ok()?);
            transitions
                .into_iter()
                .next()
                .map(|transition| transition.timestamp())
        });
        return Slot {
            key: gap_end.unwrap_or(Timestamp::MAX),
            instant: None,
        };
    }
    match ambiguous.earlier() {
        Ok(instant) => Slot {
            key: instant.timestamp(),
            instant: Some(instant),
        },
        Err(_) => Slot {
            key: Timestamp::MAX,
            instant: None,
        },
    }
}

pub(super) fn civil_time(time: &TimeOfDay) -> Time {
    Time::new(time.hour as i8, time.minute as i8, 0, 0).unwrap()
}

pub(super) fn minute_of_day(time: Time) -> i64 {
    time.hour() as i64 * MINUTES_PER_HOUR + time.minute() as i64
}
