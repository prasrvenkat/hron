//! Cron conversion: hron-to-cron and cron-to-hron.

use hron::Schedule;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // hron → cron
    let schedule = Schedule::parse("every day at 09:00")?;
    println!("hron: {}  →  cron: {}", schedule, schedule.to_cron()?);

    let schedule = Schedule::parse("every weekday at 09:00")?;
    println!("hron: {}  →  cron: {}", schedule, schedule.to_cron()?);

    let schedule = Schedule::parse("every 30 min from 00:00 to 23:59")?;
    println!("hron: {}  →  cron: {}", schedule, schedule.to_cron()?);

    // cron → hron
    println!();
    let schedule = Schedule::from_cron("*/30 * * * *")?;
    println!("cron: */30 * * * *  →  hron: {schedule}");

    let schedule = Schedule::from_cron("0 9 1 * *")?;
    println!("cron: 0 9 1 * *    →  hron: {schedule}");

    let schedule = Schedule::from_cron("0 9 * * 1-5")?;
    println!("cron: 0 9 * * 1-5  →  hron: {schedule}");

    // Inexpressible schedules return errors
    println!();
    let schedule = Schedule::parse("every 2 weeks on monday at 09:00")?;
    match schedule.to_cron() {
        Ok(cron) => println!("cron: {cron}"),
        Err(e) => println!("Cannot convert to cron: {e}"),
    }

    Ok(())
}
