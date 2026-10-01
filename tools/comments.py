"""Lists the comment lines a branch adds, so each one can be given a reason to
stay or deleted (AGENTS.md, "Comments"). A line-based scan, not a parser: a
comment marker inside a multi-line string can show up, which is harmless."""

import io
import re
import subprocess
import sys
import tokenize
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SLASH = {".rs", ".ts", ".tsx", ".js", ".mjs", ".jsx", ".go", ".java", ".cs", ".dart", ".swift"}
HASH = {".rb", ".sh", ".toml", ".yml", ".yaml"}
HASH_NAMES = {"justfile"}
# Rust lifetimes and char literals make a lone ' common there.
QUOTES = {".rs": '"'}
DIRECTIVE = re.compile(
    r"(frozen_string_literal|fmt: (skip|off|on)|pragma|noqa|type: ignore|biome-ignore"
    r"|@ts-(expect-error|ignore|self-types)|eslint-disable|go:\w+|nolint|ignore(_for_file)?:"
    r"|rubocop:|standard:)"
)
HUNK = re.compile(r"@@ -\S+ \+(\d+)(,(\d+))?")
SKIP = re.compile(r"(^|/)(node_modules|target|dist|build|\.build|vendor)/")


def added_lines(base: str) -> dict[str, set[int]]:
    # Uncommitted and new files count: the check runs before committing.
    since = git("merge-base", resolve(base), "HEAD").strip()
    added: dict[str, set[int]] = {}
    path, in_header = None, False
    diff = git("-c", "diff.noprefix=false", "diff", "--no-ext-diff", "--unified=0", since)
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            path, in_header = None, True
        elif in_header and line.startswith("+++ "):
            path = None if line == "+++ /dev/null" else line[6:]
            in_header = False
        elif path and (hunk := HUNK.match(line)):
            first, count = int(hunk[1]), int(hunk[3] or 1)
            added.setdefault(path, set()).update(range(first, first + count))
    for path in git("ls-files", "--others", "--exclude-standard").splitlines():
        lines = len((ROOT / path).read_text(encoding="utf-8", errors="replace").splitlines())
        added[path] = set(range(1, lines + 1))
    return added


def resolve(base: str) -> str:
    # A CI checkout may have origin/main but no local main.
    for ref in (base, f"origin/{base}"):
        found = subprocess.run(
            ["git", "rev-parse", "--verify", "-q", ref], cwd=ROOT, capture_output=True
        )
        if found.returncode == 0:
            return ref
    sys.exit(f"no such ref: {base}")


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-c", "core.quotepath=false", *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def scanned(path: Path) -> bool:
    return path.suffix in SLASH | HASH | {".py"} or path.name in HASH_NAMES


def comment_lines(path: Path) -> set[int]:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".py":
        return python_comment_lines(text)
    source = text.splitlines()
    hash_style = path.suffix in HASH or path.name in HASH_NAMES
    marker = "#" if hash_style else "//"
    quotes = QUOTES.get(path.suffix, "\"'`")
    lines, in_block = set(), False
    for number, line in enumerate(source, 1):
        stripped = line.strip()
        if in_block:
            lines.add(number)
            in_block = "*/" not in stripped
        elif not hash_style and stripped.startswith("/*"):
            lines.add(number)
            in_block = "*/" not in stripped[2:]
        elif stripped.startswith(marker) or trailing_comment(line, marker, quotes, hash_style):
            lines.add(number)
    return {number for number in lines if not DIRECTIVE.search(source[number - 1])}


def trailing_comment(line: str, marker: str, quotes: str, hash_style: bool) -> bool:
    quote, escaped = None, False
    for i, char in enumerate(line):
        if quote:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
        elif char in quotes:
            quote = char
        elif (
            line[:i].strip()
            and line[i - 1].isspace()
            and (line.startswith(marker, i) or (not hash_style and line.startswith("/*", i)))
        ):
            return True
    return False


def python_comment_lines(text: str) -> set[int]:
    lines = set()
    previous = None
    try:
        for token in tokenize.generate_tokens(io.StringIO(text).readline):
            if token.type == tokenize.COMMENT and not DIRECTIVE.search(token.string):
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
        if SKIP.search(name) or not path.is_file() or not scanned(path):
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
