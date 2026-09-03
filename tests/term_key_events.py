#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'bootstrap'))
from term_keys import KeyReader


def with_pipe(payload: bytes, reads: list[bytes | None]) -> None:
    rd, wr = os.pipe()
    try:
        if payload:
            os.write(wr, payload)
        reader = KeyReader(rd)
        for expected in reads:
            actual = reader.read(1 if expected is None else None)
            assert actual == expected, (payload, actual, expected)
    finally:
        os.close(wr)
        os.close(rd)


def main() -> None:
    with_pipe(b'a', [b'a'])
    with_pipe('λ'.encode(), ['λ'.encode()])
    with_pipe('€'.encode(), ['€'.encode()])
    with_pipe(b'\x1b[D', [b'\x1b[D'])
    with_pipe(b'\x1bOP', [b'\x1bOP'])

    # Alt-like/non-CSI input follows native semantics: Escape is one event and
    # the following byte is not lost.
    with_pipe(b'\x1bx', [b'\x1b', b'x'])

    # A timed read returns no event when there is no input. Keep the write end
    # open so this tests timeout rather than EOF.
    rd, wr = os.pipe()
    try:
        reader = KeyReader(rd)
        assert reader.read(1) is None
    finally:
        os.close(wr)
        os.close(rd)

    # Truncated multi-byte input is returned losslessly after the continuation
    # timeout instead of hanging or fabricating replacement text.
    rd, wr = os.pipe()
    try:
        os.write(wr, b'\xe2')
        reader = KeyReader(rd)
        assert reader.read() == b'\xe2'
    finally:
        os.close(wr)
        os.close(rd)

    print('terminal key event framing PASS')


if __name__ == '__main__':
    main()
