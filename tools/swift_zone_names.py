"""Writes swift/Sources/Hron/Evaluation/ZoneNames.swift: every IANA zone and link name that
hron accepts, keyed by its lowercase form. Foundation's TimeZone matches names only in their
exact case and cannot list links, so the Swift package carries this list.

Usage: python3 tools/swift_zone_names.py 2026e
       python3 tools/swift_zone_names.py path/to/tzdata2026e.tar.gz"""

import io
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "swift/Sources/Hron/Evaluation/ZoneNames.swift"
RELEASES = "https://data.iana.org/time-zones/releases"
DATA_FILES = [
    "africa",
    "antarctica",
    "asia",
    "australasia",
    "etcetera",
    "europe",
    "northamerica",
    "southamerica",
    "backward",
]
REJECTED_AREAS = ("systemv/", "posix/", "right/")
VERSION = re.compile(r"^\d{4}[a-z]$")


def read_tarball(release: str) -> bytes:
    if VERSION.match(release):
        with urllib.request.urlopen(f"{RELEASES}/tzdata{release}.tar.gz") as response:
            return response.read()
    return Path(release).read_bytes()


def zone_names(archive: tarfile.TarFile) -> tuple[str, list[str]]:
    version_file = archive.extractfile("version")
    if version_file is None:
        sys.exit("the tarball has no version file")
    version = version_file.read().decode().strip()
    names = set()
    for data_file in DATA_FILES:
        member = archive.extractfile(data_file)
        if member is None:
            sys.exit(f"the tarball has no {data_file} file")
        for line in member.read().decode().splitlines():
            fields = line.split("#", 1)[0].split()
            if fields[:1] == ["Zone"]:
                names.add(fields[1])
            elif fields[:1] == ["Link"]:
                names.add(fields[2])
    accepted = [name for name in names if name == "UTC" or accepted_area_location(name)]
    return version, sorted(accepted, key=str.lower)


def accepted_area_location(name: str) -> bool:
    return "/" in name and not name.lower().startswith(REJECTED_AREAS)


def swift_source(version: str, names: list[str]) -> str:
    lowercase = [name.lower() for name in names]
    if len(set(lowercase)) != len(names):
        sys.exit("two names differ only in case")
    pairs = zip(lowercase, names, strict=True)
    entries = "".join(f'  "{lower}": "{name}",\n' for lower, name in pairs)
    return (
        f"// Generated from tzdata {version} by `python3 tools/swift_zone_names.py {version}`.\n"
        "// Run it again with a newer release to regenerate; do not edit by hand.\n"
        "\n"
        "let ianaZoneNames: [String: String] = [\n"
        f"{entries}"
        "]\n"
    )


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    release = sys.argv[1]
    with tarfile.open(fileobj=io.BytesIO(read_tarball(release))) as archive:
        version, names = zone_names(archive)
    OUTPUT.write_text(swift_source(version, names))
    print(f"wrote {len(names)} names from tzdata {version} to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
