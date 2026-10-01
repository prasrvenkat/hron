"""Lists the comment lines a branch adds, so each one can be given a reason to
stay or deleted (AGENTS.md, "Comments")."""

import io
import re
import subprocess
import sys
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
C_LIKE = {".rs", ".ts", ".js", ".go", ".java", ".cs", ".dart", ".swift"}
HASH = {".rb", ".toml", ".yml", ".yaml"}
HUNK = re.compile(r"@@ -\S+ \+(\d+)(,(\d+))?")
SKIP = re.compile(r"(^|/)(node_modules|target|dist|build|\.build|vendor)/")


def added_lines(base: str) -> dict[str, set[int]]:
    # Uncommitted and new files count: the check runs before committing.
    since = git("merge-base", base, "HEAD").strip()
    added: dict[str, set[int]] = {}
    path = None
    for line in git("diff", "--unified=0", "--no-color", since).splitlines():
        if line.startswith("+++ "):
            path = None if line == "+++ /dev/null" else line[6:]
        elif path and (hunk := HUNK.match(line)):
            first, count = int(hunk[1]), int(hunk[3] or 1)
            added.setdefault(path, set()).update(range(first, first + count))
    for path in git("ls-files", "--others", "--exclude-standard").splitlines():
        lines = len((ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines())
        added[path] = set(range(1, lines + 1))
    return added


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout


def comment_lines(path: Path) -> set[int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".py":
        return python_comment_lines(text)
    marker = "#" if path.suffix in HASH else "//"
    lines, in_block = set(), False
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if in_block:
            lines.add(number)
            in_block = "*/" not in stripped
        elif path.suffix in C_LIKE and stripped.startswith("/*"):
            lines.add(number)
            in_block = "*/" not in stripped[2:]
        elif stripped.startswith(marker) or trailing_comment(line, marker):
            lines.add(number)
    return lines


def trailing_comment(line: str, marker: str) -> bool:
    quote = None
    for i, char in enumerate(line):
        if quote:
            if char == quote and line[i - 1] != "\\":
                quote = None
        elif char in "\"'`":
            quote = char
        elif line.startswith(marker, i) and line[:i].strip() and line[i - 1].isspace():
            return not line.startswith("#[", i) and not line.startswith("#!", i)
    return False


def python_comment_lines(text: str) -> set[int]:
    lines = set()
    previous = None
    try:
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type == tokenize.COMMENT:
                lines.add(token.start[0])
            elif token.type == tokenize.STRING and previous in (
                tokenize.INDENT,
                tokenize.NEWLINE,
                tokenize.NL,
                None,
            ):
                lines.update(range(token.start[0], token.end[0] + 1))
            if token.type not in (tokenize.NL, tokenize.COMMENT):
                previous = token.type
    except tokenize.TokenError:
        pass
    return lines


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "main"
    total = 0
    for name, numbers in sorted(added_lines(base).items()):
        path = ROOT / name
        if SKIP.search(name) or not path.is_file() or path.suffix not in C_LIKE | HASH | {".py"}:
            continue
        found = sorted(numbers & comment_lines(path))
        if not found:
            continue
        source = path.read_text(encoding="utf-8", errors="replace").splitlines()
        print(f"\n{name}")
        for number in found:
            print(f"  {number:5}  {source[number - 1].strip()}")
        total += len(found)
    print(f"\n{total} comment lines added since {base}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
