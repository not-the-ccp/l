#!/usr/bin/env python3
from __future__ import annotations

"""Parse, link, and type-check the freestanding core examples.

The core examples have no main convention; this is the check CI's core
job runs on them without a hosted profile.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from lang import Program  # noqa: E402


def main() -> None:
    for path in sorted((ROOT / "examples" / "core").glob("*.l")):
        Program({("example",): path.read_text(encoding="utf-8")}, host_modules={})
        print(f"{path.relative_to(ROOT)}: ok")


if __name__ == "__main__":
    main()
