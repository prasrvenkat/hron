// hron-wasm compiles this file too. It lives here because hron-cli is published to
// crates.io, which packages only the files inside the crate.

use jiff::fmt::temporal::{DateTimeParser, Pieces, PiecesOffset};
use jiff::tz::{OffsetConflict, TimeZone};
use jiff::{Timestamp, Zoned};

static PARSER: DateTimeParser = DateTimeParser::new().offset_conflict(OffsetConflict::AlwaysOffset);

/// Reads a timestamp string as spec/README.md, "Timestamps and counts", says.
/// An instant beyond jiff's range comes back as jiff's nearest limit, which
/// lies outside hron's supported range, so hron finds nothing for it.
pub fn parse_timestamp(input: &str) -> Result<Zoned, String> {
    let error = match parse_within_jiff_range(input) {
        Ok(zoned) => return Ok(zoned),
        Err(reason) => format!("invalid timestamp \"{input}\": {reason}"),
    };
    let Some((year, rest)) = split_year(input) else {
        return Err(error);
    };
    if year.abs() < 9999 {
        return Err(error);
    }
    if parse_within_jiff_range(&format!("{:+07}{rest}", stand_in_year(year))).is_err() {
        return Err(error);
    }
    let limit = if year > 0 {
        Timestamp::MAX
    } else {
        Timestamp::MIN
    };
    Ok(limit.to_zoned(TimeZone::UTC))
}

fn parse_within_jiff_range(input: &str) -> Result<Zoned, String> {
    let pieces = Pieces::parse(input).map_err(|e| e.to_string())?;
    let Some(written_offset) = pieces.offset() else {
        return Err("it has no UTC offset or Z, so it names no single instant".to_string());
    };
    let Some(annotation) = pieces.time_zone_annotation() else {
        let instant = PARSER.parse_timestamp(input).map_err(|e| e.to_string())?;
        return Ok(instant.to_zoned(TimeZone::UTC));
    };
    let zoned = PARSER.parse_zoned(input).map_err(|e| e.to_string())?;
    if let PiecesOffset::Numeric(numeric) = written_offset {
        if annotation.is_critical() && numeric.offset() != zoned.offset() {
            return Err(format!(
                "its offset {} is not the offset of its critical time zone, {}",
                numeric.offset(),
                zoned.offset()
            ));
        }
    }
    Ok(zoned)
}

fn split_year(input: &str) -> Option<(i32, &str)> {
    let digits = if input.starts_with(['+', '-']) { 7 } else { 4 };
    let year = input.get(..digits)?;
    let rest = &input[digits..];
    Some((year.parse().ok()?, rest))
}

/// A year 400 years away has the same calendar, weekdays included, and the same
/// time zone offsets: tzdb keeps a zone's first offset before its data starts and
/// repeats its last rule after the data ends. So the stand-in, which jiff can
/// represent, is valid and agrees with its critical zone exactly when the
/// original does.
fn stand_in_year(year: i32) -> i32 {
    if year > 0 {
        9200 + (year - 9200).rem_euclid(400)
    } else {
        -9599 + (year + 9599).rem_euclid(400)
    }
}
