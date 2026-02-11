//! Basic hron API walkthrough: parse, evaluate, match, display.

use hron::Schedule;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse a schedule expression
    let schedule: Schedule = "every weekday at 09:00 in UTC".parse()?;
    println!("Parsed: {schedule}");

    // Compute the next occurrence
    let now: jiff::Zoned = "2025-06-15T08:00:00+00:00[UTC]".parse()?;
    if let Some(next) = schedule.next_from(&now)? {
        println!("Next occurrence after {now}: {next}");
    }

    // Compute the next 5 occurrences
    let next_5 = schedule.next_n_from(&now, 5)?;
    println!("\nNext 5 occurrences:");
    for dt in &next_5 {
        println!("  {dt}");
    }

    // Check if a datetime matches the schedule
    let monday_9am: jiff::Zoned = "2025-06-16T09:00:00+00:00[UTC]".parse()?;
    println!("\n{monday_9am} matches: {}", schedule.matches(&monday_9am)?);

    let sunday_9am: jiff::Zoned = "2025-06-15T09:00:00+00:00[UTC]".parse()?;
    println!("{sunday_9am} matches: {}", schedule.matches(&sunday_9am)?);

    // Display roundtrips through parsing
    let roundtripped: Schedule = schedule.to_string().parse()?;
    assert_eq!(schedule.to_string(), roundtripped.to_string());
    println!("\nRoundtrip: {roundtripped}");

    Ok(())
}
