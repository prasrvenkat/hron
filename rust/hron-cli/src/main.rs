use clap::Parser;
use hron::Schedule;
use jiff::Zoned;
use std::io::{self, Write};
use std::process;

mod timestamp;

#[derive(Parser)]
#[command(name = "hron", about = "Human-readable cron", version)]
struct Cli {
    /// Schedule expression (e.g., "every weekday at 9:00")
    expression: Option<String>,

    /// Number of occurrences to show, after now or after --from (at most 1000)
    #[arg(
        short = 'n',
        long = "count",
        default_value = "1",
        conflicts_with = "to"
    )]
    count: u32,

    /// Show occurrences after this time instead of now, with a UTC offset or Z (e.g., 2026-02-06T09:00:00+01:00[Europe/Berlin])
    #[arg(long, allow_hyphen_values = true)]
    from: Option<String>,

    /// With --from, show every occurrence in (from, to] instead of a count, with a UTC offset or Z
    #[arg(long, requires = "from", allow_hyphen_values = true)]
    to: Option<String>,

    /// Output as JSON
    #[arg(long)]
    json: bool,

    /// Validate expression without computing
    #[arg(long)]
    check: bool,

    /// Show parsed AST as JSON
    #[arg(long)]
    parse: bool,

    /// Convert expression to cron
    #[arg(long)]
    to_cron: bool,

    /// Convert cron to hron expression
    #[arg(long, conflicts_with_all = ["expression", "explain"])]
    from_cron: Option<String>,

    /// Explain a cron expression in human-readable form
    #[arg(long, conflicts_with = "expression")]
    explain: Option<String>,
}

fn main() {
    let cli = Cli::parse();

    if let Some(ref cron_expr) = cli.explain {
        match Schedule::explain_cron(cron_expr) {
            Ok(explanation) => {
                print_line(&explanation);
                process::exit(0);
            }
            Err(e) => {
                eprintln!("{}", e.display_rich());
                process::exit(1);
            }
        }
    }

    if let Some(ref cron_expr) = cli.from_cron {
        match Schedule::from_cron(cron_expr) {
            Ok(schedule) => {
                print_line(&schedule.to_string());
                process::exit(0);
            }
            Err(e) => {
                eprintln!("{}", e.display_rich());
                process::exit(1);
            }
        }
    }

    let expression = match cli.expression {
        Some(ref expr) => expr.as_str(),
        None => {
            eprintln!("error: no expression provided");
            process::exit(2);
        }
    };

    let schedule = match Schedule::parse(expression) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("{}", e.display_rich());
            process::exit(1);
        }
    };

    if cli.check {
        print_line("\u{2713} valid");
        process::exit(0);
    }

    if cli.parse {
        match serde_json::to_string_pretty(&schedule) {
            Ok(json) => {
                print_line(&json);
                process::exit(0);
            }
            Err(e) => {
                eprintln!("error: failed to serialize: {e}");
                process::exit(1);
            }
        }
    }

    if cli.to_cron {
        match schedule.to_cron() {
            Ok(cron) => {
                print_line(&cron);
                process::exit(0);
            }
            Err(e) => {
                eprintln!("{}", e.display_rich());
                process::exit(1);
            }
        }
    }

    let from = match cli.from {
        Some(ref from) => timestamp_option("--from", from),
        None => Zoned::now(),
    };

    if let Some(ref to) = cli.to {
        let to = timestamp_option("--to", to);
        let results: Vec<Zoned> = schedule.between(&from, &to).collect();
        if results.is_empty() && !cli.json {
            eprintln!("no occurrences in range");
        }
        print_timestamps(&results, cli.json);
        process::exit(0);
    }

    let mut count = cli.count;
    if count > 1000 {
        eprintln!("warning: capped at 1000 occurrences");
        count = 1000;
    }

    let results = schedule.next_n_from(&from, count as usize);
    if results.is_empty() && !cli.json {
        match cli.from {
            Some(_) => eprintln!("no occurrences after --from"),
            None => eprintln!("no upcoming occurrences"),
        }
    }
    print_timestamps(&results, cli.json);
}

/// A usage error (spec/README.md, "Timestamps and counts") exits with status 2.
fn timestamp_option(option: &str, value: &str) -> Zoned {
    match timestamp::parse_timestamp(value) {
        Ok(zoned) => zoned,
        Err(e) => {
            eprintln!("error: {option}: {e}");
            process::exit(2);
        }
    }
}

fn print_timestamps(results: &[Zoned], json: bool) {
    if json {
        let strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
        print_line(&serde_json::to_string(&strings).expect("strings serialize"));
    } else {
        for z in results {
            print_line(&z.to_string());
        }
    }
}

/// Rust ignores SIGPIPE, so once a reader such as `head` has gone, writes fail
/// with BrokenPipe, where println! would panic.
fn print_line(text: &str) {
    let mut stdout = io::stdout().lock();
    if let Err(e) = writeln!(stdout, "{text}").and_then(|()| stdout.flush()) {
        if e.kind() == io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        eprintln!("error: {e}");
        process::exit(1);
    }
}
