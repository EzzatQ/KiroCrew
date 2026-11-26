"""A sliding-window rate limit for the device pairing routes.

One limiter per route family, keyed by the caller's address. It fails closed twice: an
empty key is refused, and once ``max_keys`` windows are live a key it has not seen is
refused rather than admitted by dropping a live window, so a spread of addresses cannot
reset an exhausted one. Behind a tunnel every caller shares the tunnel's address, so the
limit there is one shared budget.
"""

from __future__ import annotations

import collections
import threading
import time
from collections.abc import Callable


class SlidingWindowLimiter:
    """At most *max_calls* per *window_secs* for each key."""

    def __init__(
        self,
        max_calls: int,
        window_secs: float = 60.0,
        *,
        max_keys: int = 1024,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._max_calls = max_calls
        self._window = window_secs
        self._max_keys = max_keys
        self._clock = clock
        self._lock = threading.Lock()
        self._calls: dict[str, collections.deque[float]] = {}

    def limited(self, key: str) -> bool:
        """Count one call for *key*; ``True`` when it is over the limit."""
        if not key:
            return True
        now = self._clock()
        cutoff = now - self._window
        with self._lock:
            bucket = self._calls.get(key)
            if bucket is None:
                if len(self._calls) >= self._max_keys:
                    self._calls = {k: b for k, b in self._calls.items() if b and b[-1] >= cutoff}
                    if len(self._calls) >= self._max_keys:
                        return True
                bucket = self._calls[key] = collections.deque()
            while bucket and bucket[0] < cutoff:
                bucket.popleft()
            if len(bucket) >= self._max_calls:
                return True
            bucket.append(now)
            return False
