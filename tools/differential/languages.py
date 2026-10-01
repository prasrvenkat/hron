"""How to build and run each language's runner, and how to feed it cases."""

import json
import os
import queue
import subprocess
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import TextIO

ROOT = Path(__file__).resolve().parents[2]
RUNNERS = ROOT / "tools/differential/runners"
BUILD = ROOT / "tools/differential/.build"


@dataclass(frozen=True)
class Language:
    build: list[list[str]]
    run: list[str]
    env: dict[str, str] = field(default_factory=dict)


LANGUAGES = {
    "rust": Language(
        build=[["cargo", "build", "--release", "--quiet", "--target-dir", f"{BUILD}/rust",
                "--manifest-path", f"{RUNNERS}/rust/Cargo.toml"]],
        run=[f"{BUILD}/rust/release/hron-differential"],
    ),
    "ts": Language(
        build=[["pnpm", "-C", "ts", "install", "--frozen-lockfile"], ["pnpm", "-C", "ts", "build"]],
        run=["node", f"{RUNNERS}/ts/runner.ts"],
    ),
    "python": Language(
        build=[["uv", "sync", "--quiet", "--frozen", "--project", "python"]],
        # The venv's interpreter, not `uv run`: killing uv after a timeout would leave
        # its Python child running.
        run=[f"{ROOT}/python/.venv/bin/python", f"{RUNNERS}/python/runner.py"],
    ),
    "go": Language(
        build=[["go", "build", "-C", f"{RUNNERS}/go", "-o", f"{BUILD}/go/runner", "."]],
        run=[f"{BUILD}/go/runner"],
    ),
    "java": Language(
        build=[["mvn", "-q", "-f", "java/pom.xml", "-DskipTests", "compile"],
               ["javac", "-d", f"{BUILD}/java", "-cp", "java/target/classes",
                f"{RUNNERS}/java/Runner.java"]],
        run=["java", "-cp", os.pathsep.join(["java/target/classes", f"{BUILD}/java"]), "Runner"],
    ),
    "csharp": Language(
        build=[["dotnet", "build", f"{RUNNERS}/csharp", "-c", "Release", "-o", f"{BUILD}/csharp",
                "--nologo", "-v", "q"]],
        run=["dotnet", f"{BUILD}/csharp/Runner.dll"],
    ),
    "ruby": Language(
        build=[["bundle", "install", "--quiet"]],
        run=["bundle", "exec", "ruby", f"{RUNNERS}/ruby/runner.rb"],
        env={"BUNDLE_GEMFILE": f"{ROOT}/ruby/Gemfile"},
    ),
    "dart": Language(
        build=[["dart", "pub", "get", "--directory", f"{RUNNERS}/dart"],
               ["dart", "compile", "exe", f"{RUNNERS}/dart/runner.dart",
                "-o", f"{BUILD}/dart/runner"]],
        run=[f"{BUILD}/dart/runner"],
    ),
}  # fmt: skip


class RunnerError(Exception):
    pass


TIMEOUT = {"ok": False, "error": {"kind": "timeout"}}
EXITED = {"ok": False, "error": {"kind": "crash", "message": "the runner exited"}}


def build(name: str) -> None:
    language = LANGUAGES[name]
    (BUILD / name).mkdir(parents=True, exist_ok=True)
    for command in language.build:
        try:
            done = subprocess.run(
                command, cwd=ROOT, env=os.environ | language.env, capture_output=True, text=True
            )
        except OSError as error:
            raise RunnerError(f"{name}: `{' '.join(command)}` failed: {error}") from None
        if done.returncode != 0:
            raise RunnerError(f"{name}: `{' '.join(command)}` failed\n{done.stdout}{done.stderr}")


def run(name: str, cases: list[dict], timeout: float) -> dict[str, dict]:
    """Runs every case and returns each case's outcome by id. A case that hangs
    or kills the runner gets a timeout or crash outcome, and the runner restarts
    with the case after it. A runner that fails its first two cases that way is
    broken, not buggy, so the run stops."""
    outcomes = {}
    with open(BUILD / f"{name}.log", "w") as log:
        pending = cases
        while pending:
            pending = run_until_stuck(name, pending, timeout, outcomes, log)
            if len(cases) > 1 and all(
                outcomes.get(case["id"]) in (TIMEOUT, EXITED) for case in cases[:2]
            ):
                raise RunnerError(f"{name}: no answer to the first two cases; see {log.name}")
    return outcomes


def run_until_stuck(
    name: str, cases: list[dict], timeout: float, outcomes: dict, log: TextIO
) -> list[dict]:
    language = LANGUAGES[name]
    try:
        process = subprocess.Popen(
            language.run,
            cwd=ROOT,
            env=os.environ | language.env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
            encoding="utf-8",
        )
    except OSError as error:
        raise RunnerError(f"{name}: could not start `{' '.join(language.run)}`: {error}") from None
    lines = queue.Queue()
    threading.Thread(target=feed, args=(process.stdin, cases), daemon=True).start()
    threading.Thread(target=drain, args=(process.stdout, lines), daemon=True).start()
    try:
        for i, case in enumerate(cases):
            try:
                line = lines.get(timeout=timeout)
            except queue.Empty:
                outcomes[case["id"]] = TIMEOUT
                return cases[i + 1 :]
            if line is None:
                outcomes[case["id"]] = EXITED
                return cases[i + 1 :]
            outcomes[case["id"]] = answer(name, case, line)
        return []
    finally:
        process.kill()
        process.wait()


def answer(name: str, case: dict, line: str) -> dict:
    try:
        outcome = json.loads(line)
        answered = outcome.pop("id")
    except (ValueError, KeyError):
        raise RunnerError(f"{name}: not an answer to {case['id']}: {line!r}") from None
    if answered != case["id"]:
        raise RunnerError(f"{name}: answered {answered} instead of {case['id']}")
    return outcome


def feed(stdin: TextIO, cases: list[dict]) -> None:
    try:
        for case in cases:
            stdin.write(json.dumps(case) + "\n")
        stdin.close()
    except OSError:
        pass  # The runner was stopped after a case hung or crashed it.


def drain(stdout: TextIO, lines: queue.Queue) -> None:
    for line in stdout:
        lines.put(line)
    lines.put(None)
