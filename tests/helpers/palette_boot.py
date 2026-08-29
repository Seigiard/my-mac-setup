"""Import the command-palette plugin modules from the chezmoi source tree.

The paths arrive in PALETTE_PY / PALETTE_OPEN_PY, which tests/bashunit/palette_test.sh
points at $SOURCE_ROOT. That is the working checkout, so these tests fail on an edit
chezmoi has not applied yet -- unlike tests/bashunit/smoke_test.sh, which reads $HOME.
"""

from __future__ import annotations

import importlib.util
import os
import sys
from typing import Any


def load(module_name: str, env_var: str) -> Any:
    path = os.environ[env_var]
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def palette() -> Any:
    return load("palette", "PALETTE_PY")


def opener() -> Any:
    return load("palette_open", "PALETTE_OPEN_PY")
