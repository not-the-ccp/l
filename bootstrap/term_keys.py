from __future__ import annotations

import os
import select


class KeyReader:
    """Frame terminal input into the same key events as the native L host.

    Events are one ordinary byte, one complete UTF-8 scalar, or one CSI/SS3
    escape sequence. A bare Escape stays a separate event; a byte arriving
    after Escape that is not CSI/SS3 is pushed back for the following read.
    """

    def __init__(self, fd: int = 0):
        self.fd = fd
        self._pushback = bytearray()

    def _read_byte(self, timeout_ms: int | None) -> int | None:
        if self._pushback:
            value = self._pushback[0]
            del self._pushback[0]
            return value
        if timeout_ms is not None:
            ready, _, _ = select.select([self.fd], [], [], max(0, timeout_ms) / 1000.0)
            if not ready:
                return None
        data = os.read(self.fd, 1)
        if not data:
            return None
        return data[0]

    def read(self, timeout_ms: int | None = None) -> bytes | None:
        first = self._read_byte(timeout_ms)
        if first is None:
            return None

        out = bytearray([first])
        if first == 0x1B:
            second = self._read_byte(8)
            if second is None:
                return bytes(out)
            if second in (ord('['), ord('O')):
                out.append(second)
                while len(out) < 16:
                    value = self._read_byte(8)
                    if value is None:
                        break
                    out.append(value)
                    if 0x40 <= value <= 0x7E:
                        break
            else:
                self._pushback.append(second)
            return bytes(out)

        wanted = 1
        if first & 0xE0 == 0xC0:
            wanted = 2
        elif first & 0xF0 == 0xE0:
            wanted = 3
        elif first & 0xF8 == 0xF0:
            wanted = 4
        while len(out) < wanted:
            value = self._read_byte(8)
            if value is None:
                break
            out.append(value)
        return bytes(out)
