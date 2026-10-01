"""Compares outcomes across languages, and against a saved run."""

import json
from collections import Counter, defaultdict

ARGUMENTS = ["now", "datetime", "from", "to", "n"]
ERROR_FIELDS = ["kind", "span", "suggestion"]
# A case counts as slower only past both: a garbage collection pause can add a
# few milliseconds to any one case, while past regressions were 1000x.
SLOWER_RATIO = 3
SLOWER_FLOOR_MICROS = 20_000


def describe(case: dict) -> str:
    arguments = "".join(f" {key}={case[key]}" for key in ARGUMENTS if key in case)
    return f"{case['id']}  {case['op']} {json.dumps(case['expr'], ensure_ascii=False)}{arguments}"


def show(outcome: dict, width: int = 160) -> str:
    if outcome["ok"]:
        text = json.dumps(outcome["result"], ensure_ascii=False)
    else:
        error = outcome["error"]
        text = f"error {error['kind']}"
        if error.get("span"):
            text += f" at {error['span'][0]}..{error['span'][1]}"
        if "message" in error:
            text += f": {error['message']}"
        if error.get("suggestion"):
            text += f" (suggest {error['suggestion']!r})"
    return text if len(text) <= width else text[: width - 1] + "…"


def agreed(outcome: dict) -> dict:
    """The part of an outcome every language must agree on. The spec fixes an
    error's kind, span and suggestion, but each language words its message."""
    if outcome["ok"]:
        return outcome
    return {"ok": False, "error": {key: outcome["error"].get(key) for key in ERROR_FIELDS}}


def split(case_id: str, outcomes: dict[str, dict]) -> list[list[str]]:
    """The languages grouped by agreeing outcome, largest group first."""
    groups = defaultdict(list)
    for name, by_id in outcomes.items():
        groups[json.dumps(agreed(by_id[case_id]), sort_keys=True)].append(name)
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
    the number of outcomes, one per case and language, that changed or could
    not be compared."""
    saved_cases = {case["id"]: case for case in saved["cases"]}
    comparable = [case for case in cases if saved_cases.get(case["id"]) == case]
    uncompared = len(cases) - len(comparable)
    if uncompared:
        print(f"{uncompared} cases are new or changed since the saved run, so were not compared")
    changes = 0
    for name, after in outcomes.items():
        before = saved["outcomes"].get(name)
        if before is None:
            print(f"{name}: not in the saved run")
            changes += len(cases)
            continue
        changed = [case for case in comparable if before[case["id"]] != after[case["id"]]]
        changes += uncompared + len(changed)
        print(f"{name}: {len(changed)} changed")
        for case in changed[:examples]:
            print(f"  {describe(case)}")
            print(f"    before: {show(before[case['id']])}")
            print(f"    after:  {show(after[case['id']])}")
    return changes


def compare_times(saved: dict, cases: list[dict], micros: dict[str, dict], examples: int) -> None:
    """Prints each language's evaluation time against the saved run's, and the
    cases that became much slower. Timings are noisy, so this only informs."""
    print("\nevaluation time, before -> after")
    for name, after in micros.items():
        before = saved.get("micros", {}).get(name)
        if before is None:
            print(f"{name}: no saved timings")
            continue
        timed = [case["id"] for case in cases if case["id"] in before and case["id"] in after]
        total_before = sum(before[case_id] for case_id in timed) / 1e6
        total_after = sum(after[case_id] for case_id in timed) / 1e6
        print(f"{name}: {total_before:.2f}s -> {total_after:.2f}s")
        slower = [
            case_id
            for case_id in timed
            if after[case_id] > SLOWER_RATIO * before[case_id] + SLOWER_FLOOR_MICROS
        ]
        slower.sort(key=lambda case_id: after[case_id] - before[case_id], reverse=True)
        for case_id in slower[:examples]:
            print(f"  {case_id}: {before[case_id]}us -> {after[case_id]}us")
