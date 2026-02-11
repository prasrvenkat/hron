//! Modifier clause examples: except, until, during, starting.

use hron::Schedule;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // except — skip specific dates
    let schedule = Schedule::parse("every day at 09:00 except dec 25 in UTC")?;
    let now: jiff::Zoned = "2025-12-20T00:00:00+00:00[UTC]".parse()?;
    let next_10 = schedule.next_n_from(&now, 10)?;
    println!("Every day at 09:00 except dec 25 (next 10):");
    for dt in &next_10 {
        println!("  {dt}");
    }

    // until — stop after a date
    let schedule = Schedule::parse("every day at 09:00 until 2025-12-25 in UTC")?;
    let remaining = schedule.next_n_from(&now, 20)?;
    println!(
        "\nEvery day at 09:00 until 2025-12-25 ({} occurrences):",
        remaining.len()
    );
    for dt in &remaining {
        println!("  {dt}");
    }

    // during — only fire during specific months
    let schedule = Schedule::parse("every day at 09:00 during jan, jul in UTC")?;
    let jan1: jiff::Zoned = "2025-01-01T00:00:00+00:00[UTC]".parse()?;
    let next_5 = schedule.next_n_from(&jan1, 5)?;
    println!("\nEvery day at 09:00 during jan, jul (next 5):");
    for dt in &next_5 {
        println!("  {dt}");
    }

    // starting — anchor for multi-week intervals
    let schedule = Schedule::parse("every 2 weeks on monday at 09:00 starting 2025-01-06 in UTC")?;
    let jan6: jiff::Zoned = "2025-01-06T00:00:00+00:00[UTC]".parse()?;
    let next_4 = schedule.next_n_from(&jan6, 4)?;
    println!("\nEvery 2 weeks on monday starting 2025-01-06 (next 4):");
    for dt in &next_4 {
        println!("  {dt}");
    }

    Ok(())
}
