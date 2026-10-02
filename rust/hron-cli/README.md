# hron CLI

Command-line interface for [hron](https://github.com/simpllyf/hron) — human-readable cron expressions.

## Install

```sh
cargo install hron-cli
```

## Usage

```sh
# Next occurrence
hron "every weekday at 9:00"

# Next 5 occurrences (-n is short for --count; at most 1000)
hron "every weekday at 9:00" -n 5

# The first 3 occurrences after a timestamp instead of now
hron "every weekday at 9:00" --from 2026-02-06T12:00:00Z -n 3

# Occurrences after --from, up to and including --to
hron "every weekday at 9:00 in America/New_York" --from "2026-02-06T12:00:00+09:00[Asia/Tokyo]" --to 2026-02-10T00:00:00Z
# 2026-02-06T09:00:00-05:00[America/New_York]
# 2026-02-09T09:00:00-05:00[America/New_York]

# JSON output: an array of timestamps, [] when none is found
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

`--to` shows every occurrence up to and including it, so it takes no count. `--from-cron` and `--explain` take their cron expression in place of an hron expression, so either one beside an expression, or the two together, is a usage error. When no occurrence is found, the output is empty, or `[]` with `--json`, and without `--json` a note goes to stderr.

## Timestamps

`--from` and `--to` take a timestamp with a UTC offset or `Z`, in either case: `2026-02-06T12:00:00+09:00[Asia/Tokyo]`, `2026-02-06T03:00:00Z` and `2026-02-06t03:00:00.000z` name the same instant, and only the instant matters. The offset decides it: a zone in brackets that disagrees with the offset is ignored, unless it is marked critical (`[!Asia/Tokyo]`). A timestamp outside the supported range, 0001-01-02 to 9999-12-30, such as one with a six-digit year (`+010000-01-01T00:00:00Z`), finds no occurrences.

Every timestamp printed has seconds, an offset as `±HH:MM` and the schedule's timezone, or `UTC` when it has none. The [spec](https://github.com/simpllyf/hron/blob/main/spec/README.md#timestamps-and-counts) has the details.

## Exit status

| Status | When |
|---|---|
| 0 | success, including when no occurrence is found, and when the reader of the output (such as `head`) has closed it |
| 1 | an hron error, such as an invalid expression or cron |
| 2 | a usage error, such as a missing expression, a timestamp it cannot read, or options that cannot go together |

## License

MIT
