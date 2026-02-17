use clap::Parser;
use hron::Schedule;
use jiff::Zoned;
use std::process;

#[derive(Parser)]
#[command(name = "hron", about = "Human-readable cron", version)]
struct Cli {
    /// Schedule expression (e.g., "every weekday at 9:00")
    expression: Option<String>,

    /// Number of occurrences to show
    #[arg(short, long, default_value = "1")]
    n: u32,

    /// Start time for iterator query (ISO 8601 datetime). Shows up to 100 occurrences unless --to is specified.
    #[arg(long, conflicts_with = "n")]
    from: Option<String>,

    /// End of range for --from query (ISO 8601 datetime). When specified, shows all occurrences in (from, to].
    #[arg(long, requires = "from")]
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
                println!("{explanation}");
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
                println!("{schedule}");
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
        println!("\u{2713} valid");
        process::exit(0);
    }

    if cli.parse {
        match serde_json::to_string_pretty(&schedule) {
            Ok(json) => {
                println!("{json}");
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
                println!("{cron}");
                process::exit(0);
            }
            Err(e) => {
                eprintln!("{}", e.display_rich());
                process::exit(1);
            }
        }
    }

    // Handle --from/--to range query
    if let Some(ref from_str) = cli.from {
        let from: Zoned = match from_str.parse() {
            Ok(z) => z,
            Err(e) => {
                eprintln!("error: invalid --from datetime: {e}");
                process::exit(1);
            }
        };

        let results: Vec<Zoned> = if let Some(ref to_str) = cli.to {
            // between() query
            let to: Zoned = match to_str.parse() {
                Ok(z) => z,
                Err(e) => {
                    eprintln!("error: invalid --to datetime: {e}");
                    process::exit(1);
                }
            };

            match schedule.between(&from, &to).collect::<Result<Vec<_>, _>>() {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("{}", e.display_rich());
                    process::exit(1);
                }
            }
        } else {
            // occurrences() with default limit
            let limit = 100;
            match schedule
                .occurrences(&from)
                .take(limit)
                .collect::<Result<Vec<_>, _>>()
            {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("{}", e.display_rich());
                    process::exit(1);
                }
            }
        };

        if results.is_empty() {
            eprintln!("no occurrences in range");
            process::exit(0);
        }

        if cli.json {
            let iso_strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
            println!("{}", serde_json::to_string(&iso_strings).unwrap());
        } else {
            for z in &results {
                println!("{z}");
            }
        }
        process::exit(0);
    }

    // Default: compute next N occurrences
    let mut n = cli.n;
    if n > 1000 {
        eprintln!("warning: capped at 1000 occurrences");
        n = 1000;
    }

    let now = Zoned::now();
    let results = match schedule.next_n_from(&now, n as usize) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("{}", e.display_rich());
            process::exit(1);
        }
    };

    if results.is_empty() {
        eprintln!("no upcoming occurrences");
        process::exit(0);
    }

    if cli.json {
        let iso_strings: Vec<String> = results.iter().map(|z| z.to_string()).collect();
        println!("{}", serde_json::to_string(&iso_strings).unwrap());
    } else {
        for z in &results {
            println!("{z}");
        }
    }
}
