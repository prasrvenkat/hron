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

    /// Number of occurrences to show
    #[arg(short, long, default_value = "1")]
    n: u32,

    /// Start time for iterator query, with a UTC offset or Z (e.g., 2026-02-06T09:00:00+01:00[Europe/Berlin]). Shows up to 100 occurrences unless --to is specified.
    #[arg(long, conflicts_with = "n", allow_hyphen_values = true)]
    from: Option<String>,

    /// End of range for --from query, with a UTC offset or Z. When specified, shows all occurrences in (from, to].
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
    #[arg(long)]
    from_cron: Option<String>,

    /// Explain a cron expression in human-readable form
    #[arg(long)]
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

    if let Some(ref from_str) = cli.from {
        let from = timestamp_option("--from", from_str);

        let results: Vec<Zoned> = if let Some(ref to_str) = cli.to {
            let to = timestamp_option("--to", to_str);

            schedule.between(&from, &to).collect()
        } else {
            let limit = 100;
            schedule.occurrences(&from).take(limit).collect()
        };

        if results.is_empty() {
            eprintln!("no occurrences in range");
            process::exit(0);
        }

        print_timestamps(&results, cli.json);
        process::exit(0);
    }

    let mut n = cli.n;
    if n > 1000 {
        eprintln!("warning: capped at 1000 occurrences");
        n = 1000;
    }

    let now = Zoned::now();
    let results = schedule.next_n_from(&now, n as usize);

    if results.is_empty() {
        eprintln!("no upcoming occurrences");
        process::exit(0);
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
