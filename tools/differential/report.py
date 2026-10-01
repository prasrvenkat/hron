"""Compares outcomes across languages, and against a saved run."""

import json
from collections import Counter, defaultdict

ARGUMENTS = ["now", "datetime", "from", "to", "n"]


def describe(case: dict) -> str:
    arguments = "".join(f" {key}={case[key]}" for key in ARGUMENTS if key in case)
    return f"{case['id']}  {case['op']} {json.dumps(case['expr'], ensure_ascii=False)}{arguments}"


def show(outcome: dict, width: int = 160) -> str:
    if outcome["ok"]:
        text = json.dumps(outcome["result"], ensure_ascii=False)
    else:
        error = outcome["error"]
        text = f"error {error['kind']}" + (f": {error['message']}" if "message" in error else "")
    return text if len(text) <= width else text[: width - 1] + "…"


def split(case_id: str, outcomes: dict[str, dict]) -> list[list[str]]:
    """The languages grouped by identical outcome, largest group first."""
    groups = defaultdict(list)
    for name, by_id in outcomes.items():
        groups[json.dumps(by_id[case_id], sort_keys=True)].append(name)
    return sorted(groups.values(), key=len, reverse=True)


def report(cases: list[dict], outcomes: dict[str, dict], examples: int) -> int:
    """Prints a summary and the divergences grouped by how the languages split.
    Returns the number of divergent cases."""
    divergent = [(case, groups) for case in cases if len(groups := split(case["id"], outcomes)) > 1]
    print(f"{len(cases) - len(divergent)} cases agree, {len(divergent)} diverge\n")
    print_table(cases, outcomes, divergent)

    by_split = defaultdict(list)
    for case, groups in divergent:
        by_split[case["op"], " | ".join(" ".join(group) for group in groups)].append((case, groups))
    for (op, languages), items in sorted(by_split.items(), key=lambda entry: -len(entry[1])):
        print(f"\n{op}, {len(items)} cases: {languages}")
        for case, groups in items[:examples]:
            print(f"  {describe(case)}")
            for group in groups:
                print(f"    {' '.join(group)}: {show(outcomes[group[0]][case['id']])}")
    return len(divergent)


def print_table(cases: list[dict], outcomes: dict[str, dict], divergent: list) -> None:
    """Per language: outcomes by kind, and how often a larger group outvotes it."""
    print(f"{'':8}{'ok':>7}{'error':>7}{'crash':>7}{'timeout':>9}{'outvoted':>10}")
    for name, by_id in outcomes.items():
        kinds = Counter(by_id[case["id"]].get("error", {}).get("kind", "ok") for case in cases)
        crash, timeout = kinds["crash"], kinds["timeout"]
        error = len(cases) - kinds["ok"] - crash - timeout
        outvoted = 0
        for _, groups in divergent:
            own = next(group for group in groups if name in group)
            outvoted += len(own) < len(groups[0])
        print(f"{name:8}{kinds['ok']:>7}{error:>7}{crash:>7}{timeout:>9}{outvoted:>10}")


def compare(saved: dict, cases: list[dict], outcomes: dict[str, dict], examples: int) -> int:
    """Prints each language's outcomes that differ from the saved run. Returns
    the number of outcomes that changed or could not be compared."""
    saved_cases = {case["id"]: case for case in saved["cases"]}
    comparable = [case for case in cases if saved_cases.get(case["id"]) == case]
    changes = len(cases) - len(comparable)
    if changes:
        print(f"{changes} cases are not in the saved run, so their outcomes were not compared")
    for name, after in outcomes.items():
        before = saved["outcomes"].get(name)
        if before is None:
            print(f"{name}: not in the saved run")
            changes += len(cases)
            continue
        changed = [case for case in comparable if before[case["id"]] != after[case["id"]]]
        changes += len(changed)
        print(f"{name}: {len(changed)} changed")
        for case in changed[:examples]:
            print(f"  {describe(case)}")
            print(f"    before: {show(before[case['id']])}")
            print(f"    after:  {show(after[case['id']])}")
    return changes
