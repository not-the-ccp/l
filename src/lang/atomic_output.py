from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Callable


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
