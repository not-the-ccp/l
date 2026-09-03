from __future__ import annotations

import errno
import signal

from core import HostModule, SomeVal, name_ty, opt


class LinuxSignalHost:
    """Process-global signal-disposition operations for the Linux hosted profile."""

    @staticmethod
    def _set(number, disposition):
        try:
            signal.signal(int(number), disposition)
            return None
        except OSError as exc:
            return SomeVal(int(exc.errno or errno.EIO))
        except (ValueError, OverflowError):
            return SomeVal(errno.EINVAL)

    def _ignore(self, number):
        return self._set(number, signal.SIG_IGN)

    def _default(self, number):
        return self._set(number, signal.SIG_DFL)

    def module(self) -> HostModule:
        host = HostModule(("linux", "process", "signal"))
        i64_ty = name_ty("i64")
        result_ty = opt(i64_ty)
        host.function("ignore", [i64_ty], result_ty, self._ignore)
        host.function("default", [i64_ty], result_ty, self._default)
        return host

    def modules(self) -> dict[tuple[str, ...], HostModule]:
        return {("linux", "process", "signal"): self.module()}
