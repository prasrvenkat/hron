"""Runs every hron implementation on the same cases and reports where they
disagree. Exits 1 on any divergence (with --compare, on any change), and 2 when
a runner fails to build or answer."""

import argparse
import json
import sys
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from cases import generate
from languages import LANGUAGES, RunnerError, build, run
from report import compare, report


def json_file(path: str) -> object:
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError) as error:
        raise argparse.ArgumentTypeError(str(error)) from None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="comma-separated languages, e.g. rust,go")
    parser.add_argument("--cases", type=json_file, help="run the cases in this JSON file instead")
    parser.add_argument("--save", type=Path, help="write the cases and every outcome to this file")
    parser.add_argument("--compare", type=json_file, help="report outcomes changed since --save")
    parser.add_argument("--no-build", action="store_true", help="skip building the runners")
    parser.add_argument("--timeout", type=float, default=10, help="seconds per case (default 10)")
    parser.add_argument("--examples", type=int, default=3, help="examples per group (default 3)")
    args = parser.parse_args()
    args.names = args.only.split(",") if args.only else list(LANGUAGES)
    if unknown := [name for name in args.names if name not in LANGUAGES]:
        parser.error(f"unknown languages: {', '.join(unknown)} (known: {', '.join(LANGUAGES)})")
    if len(set(args.names)) < len(args.names):
        parser.error("--only names a language twice")
    if args.compare and args.no_build:
        parser.error("--compare needs fresh builds, so it cannot be used with --no-build")
    if args.cases is None:
        args.cases = generate()
    ids = Counter(case["id"] for case in args.cases)
    if duplicates := [case_id for case_id, count in ids.items() if count > 1]:
        parser.error(f"duplicate case ids: {', '.join(duplicates[:5])}")
    return args


def timed_run(name: str, cases: list[dict], timeout: float) -> dict[str, dict]:
    start = time.monotonic()
    outcomes = run(name, cases, timeout)
    print(f"{name}: {len(cases)} cases in {time.monotonic() - start:.1f}s", file=sys.stderr)
    return outcomes


def main() -> int:
    args = parse_args()
    names, cases = args.names, args.cases

    start = time.monotonic()
    try:
        with ThreadPoolExecutor(len(names)) as pool:
            if not args.no_build:
                print(f"building {', '.join(names)}", file=sys.stderr)
                list(pool.map(build, names))
            runs = pool.map(lambda name: timed_run(name, cases, args.timeout), names)
            outcomes = dict(zip(names, runs, strict=True))
    except RunnerError as error:
        print(error, file=sys.stderr)
        return 2
    print(f"{len(cases)} cases, {len(names)} languages, {time.monotonic() - start:.0f}s")

    if args.save:
        args.save.write_text(json.dumps({"cases": cases, "outcomes": outcomes}))
    if args.compare:
        return 1 if compare(args.compare, cases, outcomes, args.examples) else 0
    return 1 if report(cases, outcomes, args.examples) else 0


if __name__ == "__main__":
    sys.exit(main())
