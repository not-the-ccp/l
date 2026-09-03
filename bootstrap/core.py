from __future__ import annotations

"""Public bootstrap frontend module.

The historical implementation is kept in ``_core_impl``. Feature layers are
installed here before the public names are re-exported so existing tools can keep
using ``from core import ...`` while language features remain independently
reviewable.
"""

import _core_impl as _impl
from const_arrays import install as _install_const_arrays
from literal_ranges import install as _install_literal_ranges

_install_const_arrays(_impl)
_install_literal_ranges(_impl)

globals().update({
    name: value
    for name, value in vars(_impl).items()
    if not name.startswith("_")
})
