#!/usr/bin/env python3
"""Compatibility entry point that executes the managed recovery engine."""
from pathlib import Path


ENGINE = Path(__file__).resolve().parents[2] / "home/dot_local/lib/intercom-claim-recovery.py"
__file__ = str(ENGINE)
exec(compile(ENGINE.read_bytes(), __file__, "exec"), globals())
