"""Importing the ``kiro_crew.acp`` package loads none of its modules.

The package reads each public name from its owner on first access, so a module or test
that imports one small ``kiro_crew.acp`` module does not also load the client and
everything under it. Imports are measured in a fresh interpreter: the test process has
already imported most of the tree.
"""

from __future__ import annotations

import importlib
import subprocess
import sys

import pytest

import kiro_crew.acp as package
from kiro_crew.acp import types as acp_types
from kiro_crew.testing.wait import default_timeout

#: One child runs every import-order case, in this order, and prints one line per case.
#: The package is its first import; ``kas_hook_coverage`` comes before anything that
#: loads ``kas_permissions``; the session start is reached without the facade.
_CHILD = """\
import sys
import kiro_crew.acp
print(",".join(sorted(m for m in sys.modules if m.split(".")[0] == "kiro_crew")))
import kiro_crew.acp.kas_hook_coverage
from kiro_crew.acp import client_class, client_start
print("kiro_crew.acp.client" in sys.modules, callable(client_start._resolve_spawn_env))
"""


def test_the_acp_package_and_its_import_orders_in_a_fresh_interpreter() -> None:
    res = subprocess.run(
        [sys.executable, "-c", _CHILD],
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=default_timeout(),
    )
    assert res.returncode == 0, res.stderr
    loaded, session_start = res.stdout.splitlines()
    assert set(loaded.split(",")) == {"kiro_crew", "kiro_crew.acp"}, loaded
    assert session_start == "False True", "facade loaded, resolver bound: " + session_start


def test_every_public_name_is_read_from_its_owner(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in package.__all__:
        owner = importlib.import_module(package._OWNERS[name])
        assert getattr(package, name) is getattr(owner, name)
    assert set(package.__all__) <= set(dir(package))
    stand_in = type("StandIn", (), {})
    monkeypatch.setattr(acp_types, "AcpEvent", stand_in)
    assert package.AcpEvent is stand_in
