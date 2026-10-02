import json
from collections import Counter, defaultdict

from cases import meant_to_parse

ARGUMENTS = ["now", "datetime", "from", "to", "n"]
ERROR_FIELDS = ["kind", "message", "span", "suggestion"]
PARSE_KINDS = ["lex", "parse"]
# A case counts as slower only past both, as garbage collection pauses and JIT
# warm-up can add tens of milliseconds to any one case.
SLOWER_RATIO = 3
SLOWER_FLOOR_MICROS = 20_000
# Splits that are no hron bug, by case family: the one language that may answer alone, and why.
EXPECTED_SPLITS = {
    "subminute": ("csharp", "C# keeps offsets in whole minutes, spec/README.md Timezone data"),
}


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
    if outcome["ok"]:
        return outcome
    return {"ok": False, "error": {key: outcome["error"].get(key) for key in ERROR_FIELDS}}


def split(case_id: str, outcomes: dict[str, dict]) -> list[list[str]]:
    groups = defaultdict(list)
    for name, by_id in outcomes.items():
        groups[json.dumps(agreed(by_id[case_id]), sort_keys=True)].append(name)
    return sorted(groups.values(), key=len, reverse=True)


def expected_reason(case: dict, groups: list[list[str]], outcomes: dict[str, dict]) -> str | None:
    family = case["id"].rsplit("-", 1)[0]
    if family not in EXPECTED_SPLITS:
        return None
    alone, reason = EXPECTED_SPLITS[family]
    if len(groups) != 2 or groups[1] != [alone] or len(groups[0]) < 2:
        return None
    return reason if outcomes[alone][case["id"]]["ok"] else None


def report(cases: list[dict], outcomes: dict[str, dict], examples: int) -> int:
    divergent, expected = [], defaultdict(list)
    for case in cases:
        groups = split(case["id"], outcomes)
        if len(groups) == 1:
            continue
        if reason := expected_reason(case, groups, outcomes):
            expected[reason].append((case, groups))
        else:
            divergent.append((case, groups))
    split_as_expected = sum(len(items) for items in expected.values())
    agree = len(cases) - len(divergent) - split_as_expected
    print(f"{agree} cases agree, {len(divergent)} diverge, {split_as_expected} split as expected\n")
    print_table(cases, outcomes, divergent)

    by_split = defaultdict(list)
    for case, groups in divergent:
        by_split[case["op"], " | ".join(" ".join(group) for group in groups)].append((case, groups))
    for (op, languages), items in sorted(by_split.items(), key=lambda entry: -len(entry[1])):
        print(f"\n{op}, {len(items)} cases: {languages}")
        print_examples(items[:examples], outcomes)
    for reason, items in expected.items():
        print(f"\nexpected: {reason}, {len(items)} cases")
        print_examples(items[:examples], outcomes)
    return len(divergent)


def print_examples(items: list[tuple[dict, list[list[str]]]], outcomes: dict[str, dict]) -> None:
    for case, groups in items:
        print(f"  {describe(case)}")
        for group in groups:
            print(f"    {' '.join(group)}: {show(outcomes[group[0]][case['id']])}")


def print_table(cases: list[dict], outcomes: dict[str, dict], divergent: list) -> None:
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


def warn_unparsed(cases: list[dict], outcomes: dict[str, dict]) -> None:
    """Warns about generated expressions meant to parse that every language
    rejects, which would otherwise pass as agreement."""
    unparsed = [
        case
        for case in cases
        if meant_to_parse(case)
        and all(
            by_id[case["id"]].get("error", {}).get("kind") in PARSE_KINDS
            for by_id in outcomes.values()
        )
    ]
    if unparsed:
        print(f"warning: {len(unparsed)} generated cases meant to parse fail to parse, e.g.")
        for case in unparsed[:3]:
            print(f"  {describe(case)}")


def comparable_cases(saved: dict, cases: list[dict]) -> list[dict]:
    saved_cases = {case["id"]: case for case in saved["cases"]}
    return [case for case in cases if saved_cases.get(case["id"]) == case]


def compare(
    saved: dict,
    cases: list[dict],
    comparable: list[dict],
    outcomes: dict[str, dict],
    examples: int,
) -> int:
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


def compare_times(
    saved: dict, comparable: list[dict], micros: dict[str, dict[str, int]], examples: int
) -> None:
    """Timings are noisy, so this only informs."""
    if "micros" not in saved:
        print("\nthe saved run has no timings")
        return
    print("\nevaluation time, before -> after")
    for name, after in micros.items():
        before = saved["micros"].get(name)
        if before is None:
            print(f"{name}: not in the saved run")
            continue
        timed = [case for case in comparable if case["id"] in before and case["id"] in after]
        total_before = sum(before[case["id"]] for case in timed) / 1e6
        total_after = sum(after[case["id"]] for case in timed) / 1e6
        slower = [case for case in timed if is_slower(before[case["id"]], after[case["id"]])]
        slower.sort(key=lambda case: after[case["id"]] - before[case["id"]], reverse=True)
        print(f"{name}: {total_before:.2f}s -> {total_after:.2f}s, {len(slower)} cases slower")
        for case in slower[:examples]:
            print(f"  {describe(case)}")
            print(f"    {before[case['id']]}us -> {after[case['id']]}us")


def is_slower(before: int, after: int) -> bool:
    return after >= SLOWER_RATIO * before and after - before >= SLOWER_FLOOR_MICROS
