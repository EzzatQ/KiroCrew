"""Per-test resets of process-global ``kiro_crew.agent_scratch_trees`` state.

Part of ``test/conftest.py``, which imports and re-binds these names so pytest registers
each fixture as the suite conftest's own; see the import block there. Plain module,
never collected.
"""

from __future__ import annotations

import sys

from conftest_guards import per_test_guard


@per_test_guard
def _forget_unpersisted_quarantine_marks():
    """Start and end each test with no quarantine mark held in memory only.

    ``agent_scratch_trees._QUARANTINE_LIVE`` keeps a mark the tree index refused,
    keyed by the directory's basename, for the life of the process. Tests reuse
    those names under fresh scratch roots, so a mark one test held would refuse an
    unmarked directory in the next.
    """

    def clear():
        # getattr: prove.py runs these guards against the tree with the fix reverted.
        live = getattr(sys.modules.get("kiro_crew.agent_scratch_trees"), "_QUARANTINE_LIVE", None)
        if live is not None:
            live.clear()

    clear()
    try:
        yield
    finally:
        clear()
