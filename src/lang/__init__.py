from __future__ import annotations

"""Public bootstrap frontend module.

The historical implementation is kept in ``_core_impl``. Feature layers are
installed here before the public names are re-exported so existing tools can keep
using ``from core import ...`` while language features remain independently
reviewable.
"""

from lang import _core as _impl

globals().update({
    name: value
    for name, value in vars(_impl).items()
    if not name.startswith("_")
})
