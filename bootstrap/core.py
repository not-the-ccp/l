from __future__ import annotations

"""Public bootstrap frontend module.

Re-exports everything from ``_core_impl`` so that downstream tools can use
``from core import ...``. The implementation is split across several modules
but presented as a single public surface.
"""

import _core_impl as _impl

globals().update(
    {name: value for name, value in vars(_impl).items() if not name.startswith("_")}
)
