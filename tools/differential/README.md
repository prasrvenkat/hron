# Differential testing

Runs all eight implementations on the same generated cases and reports every case where their answers differ. The conformance suite checks the cases someone thought to write down; this finds the ones nobody did. It also shows that a refactor changed nothing: save one run's answers, then compare a later run against them.

It is a developer tool, not a CI check.

## Usage

```sh
just diff                                                   # build the runners, run the cases, report divergences
just diff --only rust,go                                    # run a subset of languages
just diff --save tools/differential/.build/before.json      # save every case and answer
just diff --compare tools/differential/.build/before.json   # report what changed since the save
just diff --cases mine.json                                 # run hand-written cases instead
just diff --stress                                          # run the DST stress cases instead
```

| Flag | |
|---|---|
| `--only LANGS` | Comma-separated languages: `rust`, `ts`, `python`, `go`, `java`, `csharp`, `ruby`, `dart`. |
| `--cases FILE` | A JSON array of cases to run in place of the generated ones. |
| `--stress` | Run the DST stress cases (below) in place of the default ones. |
| `--save FILE` | Write the cases, every language's answers and how long each took. |
| `--compare FILE` | Compare each language's answers with a `--save` file instead of with each other, including error messages, then each language's total evaluation time and the cases that became at least 3x and 20 ms slower. A refactor should show zero changes and no slowdown. Runners run in parallel, so compare timings only between runs of the same languages on an otherwise idle machine. |
| `--no-build` | Skip building the runners. Not allowed with `--compare`, which would then test stale builds. |
| `--timeout SECONDS` | How long one case may take before it is reported as a timeout (default 10). |
| `--examples N` | Examples printed per group of divergences (default 3). |

The exit status is 0 when every language agrees (with `--compare`, when every outcome was compared and none changed), 1 when they do not, and 2 for bad arguments or input files, or when a runner cannot be built, started or answer at all.

Generated cases whose expression is meant to parse but fails to in every language are reported as a warning, since they would otherwise pass as agreement.

Divergences are grouped by operation and by how the languages split, largest group first, so a bug shows up as one group for each operation it affects, however many cases hit it. Languages agree on an error when its kind, message, span and suggestion all match, as the spec fixes each of them.

## Cases

`cases.py` generates about 25,000 cases from a fixed seed: every expression kind with random trailing clauses and timezones (zoneless schedules also get times written in other zones), schedules at, just before and just after the wall-clock times that each 2026 DST transition skips or repeats in eight zones (and Apia's transitions in 2011, including its skipped day), with `now` a day before, a minute before and a minute after the transition, month ends, leap days, nearest weekday, `starting` and `until`, the edges of the supported range, huge intervals, schedules that fire rarely or never (so the search runs to its horizon), invalid and mutated expressions, and cron strings.

`--stress` runs a larger DST set in its place: about 900,000 cases, generated in a few seconds. From Python's timezone data for 1971 to 2035 it takes every transition (other than a zone's first) whose skipped or repeated wall-clock range crosses midnight (such as Newfoundland's fall-back from 00:01 to 23:01) or lasts a day or more (Apia skipping 2011-12-30), one transition for each kind of range that starts or ends at midnight, and one transition in each of ten other zones chosen by the seed. Around each it builds about 100 schedules that fire in, beside and across the range: daily times and pairs of times either side of it, weekly, monthly, yearly, nearest weekday, `except`, `until`, `starting` and interval slots. Each is evaluated with `next` and `prev` from instants between two days before and two days after the transition, with `next`, `prev` and `matches` at each wall time read with either offset, and with `between` over the week around it. Rust and Go run it in under a minute; all eight take about three minutes and 4 GB of memory.

A case is a JSON object:

```json
{"id": "dst-12", "op": "next", "expr": "every day at 02:30 in America/New_York", "now": "2026-03-08T01:59:00-05:00[America/New_York]"}
```

| `op` | Arguments | Result |
|---|---|---|
| `parse` | | `toString` of the schedule |
| `toCron` | | the cron string |
| `fromCron` | (`expr` is cron) | `toString` of the schedule |
| `next`, `prev` | `now` | a timestamp or `null` |
| `nextN` | `now`, `n` | a list of timestamps |
| `occurrences` | `from`, `n` | the first `n` timestamps |
| `between` | `from`, `to` | a list of timestamps |
| `matches` | `datetime` | a boolean |

Timestamps use the spec's form, `2026-03-08T03:30:00-04:00[America/New_York]`.

A runner answers each case with one line, `{"id", "ok": true, "result", "micros"}` or `{"id", "ok": false, "error", "micros"}`, where `micros` is how long it took to evaluate the case. For a hron error, `error` is `{"kind", "message", "span", "suggestion"}`, where `kind` is `lex`, `parse`, `eval` or `cron`, `span` is `[start, end]` in code points or `null`, and `suggestion` is a string or `null`. Any other exception is `{"kind": "crash", "message"}`. The driver records `timeout` for a case that hangs and `crash` for one that kills the runner, then restarts the runner from the next case; a runner that hangs or dies on its first two cases stops the run. Each runner's stderr goes to `.build/<lang>.log`.

## Adding a language

1. Add `runners/<lang>/`: a small program that depends on the in-repo implementation by path, reads one case per line from stdin, and writes one answer per line to stdout, flushing each.
2. Add its build and run commands to `LANGUAGES` in `languages.py`.
