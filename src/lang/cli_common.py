"""Shared command-line interface helpers for the Python bootstrap drivers.

The toolchain version is single-sourced from the ``VERSION`` file at the
repository root and read at import time; do not duplicate the version
string anywhere else. Color-aware diagnostic labels and LangError rendering.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path


def _read_version():
    """Read the toolchain version from the repository-root VERSION file."""
    for parent in Path(__file__).resolve().parents:
        candidate = parent / "VERSION"
        if candidate.is_file():
            try:
                return candidate.read_text(encoding="utf-8").strip()
            except OSError:
                break
    return "unknown"


VERSION = _read_version()


def _use_color(stream=sys.stderr):
    """Report whether a stream should receive ANSI color output."""
    return (
        bool(getattr(stream, "isatty", lambda: False)())
        and "NO_COLOR" not in os.environ
    )


def _c(code, text):
    """Wrap text in an ANSI color code when color output is enabled."""
    return f"\x1b[{code}m{text}\x1b[0m" if _use_color() else text


def fail_label(kind="error"):
    """Render a failure label for diagnostics."""
    return _c("1;31", kind)


def note_label():
    """Render a note label for diagnostics."""
    return _c("1;36", "note")


def emit_lang_error(exc, fallback: Path | None = None):
    """Render a LangError with source context to stderr."""
    path = getattr(exc, "path", None)
    span = getattr(exc, "span", None)
    msg = getattr(exc, "msg", str(exc))
    if path is not None:
        path = Path(path)
    if span is not None and path is not None and path.is_file():
        print(f"{path}:{span.line}:{span.col}: {fail_label()}: {msg}", file=sys.stderr)
        try:
            line = path.read_text(encoding="utf-8").splitlines()[span.line - 1]
            n = str(span.line)
            print(f" {n} │ {line}", file=sys.stderr)
            width = max(
                1, (span.end_col - span.col) if span.end_line == span.line else 1
            )
            print(
                f" {' '*len(n)} │ {' '*(max(1,span.col)-1)}{_c('1;31','^'+'~'*(width-1))}",
                file=sys.stderr,
            )
        except Exception:
            pass
    elif span is not None and fallback is not None and Path(fallback).is_file():
        # We know the source position but not reliably which linked module owns it.
        # Avoid printing a possibly-wrong excerpt; still expose the useful position.
        print(
            f"{fallback}:{span.line}:{span.col}: {fail_label()}: {msg}", file=sys.stderr
        )
    else:
        print(f"{fail_label()}: {msg}", file=sys.stderr)
