# hron CLI

Command-line interface for [hron](https://github.com/prasrvenkat/hron) — human-readable cron expressions.

## Install

```sh
cargo install hron-cli
```

## Usage

```sh
# Next occurrence
hron "every weekday at 9:00"

# Next 5 occurrences
hron "every weekday at 9:00" -n 5

# JSON output
hron "every weekday at 9:00" --json

# Validate without computing
hron "every weekday at 9:00" --check

# Show parsed AST
hron "every weekday at 9:00" --parse

# Convert to cron
hron "every day at 9:00" --to-cron

# Convert from cron
hron --from-cron "0 9 * * *"

# Explain a cron expression
hron --explain "0 9 * * 1-5"
```

## License

MIT
