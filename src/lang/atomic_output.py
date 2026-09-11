"""Atomic file publication for compiler drivers.

Build artifacts are staged beside their destination and moved into place
with os.replace only after a successful build, so a failed compile can
never truncate an existing output.
"""
from __future__ import annotations

import os
import tempfile
from collections.abc import Callable
from pathlib import Path


def publish_after_success(output: Path, build: Callable[[Path], None]) -> None:
    """Build beside *output* and replace the destination only after success.

    Staging in the destination directory keeps publication on one filesystem,
    so ``os.replace`` is atomic. A failed compiler/linker invocation cannot
    truncate or otherwise damage an existing destination.
    """
    output = output.resolve()
    with tempfile.TemporaryDirectory(
        prefix=f".{output.name}.stage-", dir=output.parent
    ) as directory:
        staged = Path(directory) / output.name
        build(staged)
        os.replace(staged, output)
