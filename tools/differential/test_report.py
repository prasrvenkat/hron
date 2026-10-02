import pytest
from report import EXPECTED_SPLITS, report

RIGHT = {"ok": True, "result": "1971-06-01T09:00:00-00:44:30[Africa/Monrovia]"}
ROUNDED = {"ok": True, "result": "1971-06-02T08:59:30-00:44:30[Africa/Monrovia]"}
CRASH = {"ok": False, "error": {"kind": "crash", "message": "ArgumentNullException: now"}}
TIMEOUT = {"ok": False, "error": {"kind": "timeout"}}
SUBMINUTE_REASON = EXPECTED_SPLITS["subminute"][1]


def case(case_id: str) -> dict:
    return {
        "id": case_id,
        "op": "next",
        "expr": "every day at 09:00 in Africa/Monrovia",
        "now": "1971-06-01T08:59:40-00:44:30[Africa/Monrovia]",
    }


def run(
    case_id: str, by_language: dict[str, dict], capsys: pytest.CaptureFixture[str]
) -> tuple[int, str]:
    outcomes = {name: {case_id: outcome} for name, outcome in by_language.items()}
    divergent = report([case(case_id)], outcomes, examples=3)
    return divergent, capsys.readouterr().out


def test_csharp_alone_with_a_result_in_subminute_is_expected(
    capsys: pytest.CaptureFixture[str],
) -> None:
    divergent, out = run("subminute-1", {"rust": RIGHT, "go": RIGHT, "csharp": ROUNDED}, capsys)
    assert divergent == 0
    assert out.startswith("0 cases agree, 0 diverge, 1 split as expected\n")
    assert f"\nexpected: {SUBMINUTE_REASON}, 1 cases\n" in out
    assert "    csharp: " in out


@pytest.mark.parametrize("outcome", [CRASH, TIMEOUT], ids=["crash", "timeout"])
def test_csharp_alone_without_a_result_in_subminute_diverges(
    outcome: dict, capsys: pytest.CaptureFixture[str]
) -> None:
    divergent, out = run("subminute-1", {"rust": RIGHT, "go": RIGHT, "csharp": outcome}, capsys)
    assert divergent == 1
    assert out.startswith("0 cases agree, 1 diverge, 0 split as expected\n")
    assert "\nnext, 1 cases: rust go | csharp\n" in out
    assert "expected:" not in out


def test_csharp_with_another_language_in_subminute_diverges(
    capsys: pytest.CaptureFixture[str],
) -> None:
    divergent, out = run(
        "subminute-1",
        {"rust": RIGHT, "go": RIGHT, "python": ROUNDED, "csharp": ROUNDED},
        capsys,
    )
    assert divergent == 1
    assert out.startswith("0 cases agree, 1 diverge, 0 split as expected\n")
    assert "\nnext, 1 cases: rust go | python csharp\n" in out
    assert "expected:" not in out


def test_two_languages_in_subminute_diverge(capsys: pytest.CaptureFixture[str]) -> None:
    divergent, out = run("subminute-1", {"rust": RIGHT, "csharp": ROUNDED}, capsys)
    assert divergent == 1
    assert out.startswith("0 cases agree, 1 diverge, 0 split as expected\n")
    assert "\nnext, 1 cases: rust | csharp\n" in out
    assert "expected:" not in out


def test_csharp_alone_in_another_family_diverges(capsys: pytest.CaptureFixture[str]) -> None:
    divergent, out = run("dst-1", {"rust": RIGHT, "go": RIGHT, "csharp": ROUNDED}, capsys)
    assert divergent == 1
    assert out.startswith("0 cases agree, 1 diverge, 0 split as expected\n")
    assert "\nnext, 1 cases: rust go | csharp\n" in out
    assert "expected:" not in out
