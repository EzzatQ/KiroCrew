"""The one-shot pairing claim of a QR link: sign in and pair a phone with one scan.

The owner, signed in on the dashboard, asks for a mobile link with ``pair: true``.
That link carries the signed claim ``device_pair_once``; the session it becomes keeps
it. A session with the claim may answer ONE pairing request, and only one that:

* was created within :data:`PAIR_WINDOW_SECS` after the link was first redeemed (and
  not before it),
* came from the address that redeemed the link, and
* is answered while the claim is unspent and no older than :data:`PAIR_CLAIM_TTL_SECS`.

The redemption (address, time) and the spent flag live here, in memory, keyed by the
credential family of the link. After a gateway restart the record is gone and a claim
session is refused: the fail-closed direction. The claim is carried to the session
only by the link exchange; refresh, a lent link and every other mint drop it, and a
session without it behaves as before.

shortcut: the window is a constant, not a config key; add a ``dashboard`` section field
when owners need to tune it.
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable

from aiohttp import web

from kiro_crew.dashboard.origin import is_proxied_request

#: The signed claim a pair link and the session it becomes carry.
PAIR_CLAIM = "device_pair_once"
#: A pairing request must be created within this long after the link redeemed.
PAIR_WINDOW_SECS = 120
#: The claim stops working this long after the link redeemed, spent or not.
PAIR_CLAIM_TTL_SECS = 600
_MAX_RECORDS = 256

#: Refusal codes, in the order they are checked.
UNKNOWN = "pair_claim_unknown"
EXPIRED = "pair_claim_expired"
SPENT = "pair_claim_spent"
NO_ADDRESS = "pair_claim_address_unknown"
WRONG_ADDRESS = "pair_claim_wrong_address"
TOO_EARLY = "pair_claim_request_before_link"
TOO_LATE = "pair_claim_request_too_late"


def source_of(request: web.Request) -> str:
    """The caller's own address, or ``""`` when a tunnel or proxy hides it."""
    return "" if is_proxied_request(request) else request.remote or ""


def claim_family(request: web.Request) -> str:
    """The credential family of the session when it carries the pair claim, else ``""``.

    Reads the token token auth validated for this request (``request["auth_token"]``);
    nothing else is trusted. A token that cannot be decoded has no claim.
    """
    from kiro_crew.dashboard.token_auth_tokens import _b64url_decode, token_family

    token = request.get("auth_token", "")
    if not isinstance(token, str) or "." not in token:
        return ""
    try:
        data = json.loads(_b64url_decode(token.split(".", 1)[0]))
    except Exception:
        return ""
    if not isinstance(data, dict) or str(data.get(PAIR_CLAIM, "")) != "1":
        return ""
    return token_family(data)


class PairClaims:
    """What the gateway knows about each redeemed pair link."""

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock
        self._lock = threading.Lock()
        self._records: dict[str, dict[str, object]] = {}

    def redeemed(self, family: str, source: str) -> None:
        """Record the first redemption of a pair link. Later ones change nothing."""
        if not family:
            return
        now = self._clock()
        with self._lock:
            self._records = {
                f: r
                for f, r in self._records.items()
                if now - float(r["at"]) < PAIR_CLAIM_TTL_SECS  # type: ignore[arg-type]
            }
            if family in self._records or len(self._records) >= _MAX_RECORDS:
                return
            self._records[family] = {"at": now, "source": source, "spent": False}

    def refusal(self, family: str, *, created_at: float, source: str) -> str:
        """Why the session of *family* may not answer a request made at *created_at* from
        *source*, or ``""`` when it may. Changes nothing."""
        now = self._clock()
        with self._lock:
            record = self._records.get(family)
            if record is None:
                return UNKNOWN
            redeemed_at = float(record["at"])  # type: ignore[arg-type]
            if now - redeemed_at >= PAIR_CLAIM_TTL_SECS:
                return EXPIRED
            if record["spent"]:
                return SPENT
            link_source = str(record["source"])
            if not link_source or not source:
                return NO_ADDRESS
            if link_source != source:
                return WRONG_ADDRESS
            if created_at < int(redeemed_at):
                return TOO_EARLY
            if created_at > redeemed_at + PAIR_WINDOW_SECS:
                return TOO_LATE
            return ""

    def spend(self, family: str) -> bool:
        """Mark the claim spent. ``False`` when it already was or is unknown, so of two
        racing approvals one wins."""
        with self._lock:
            record = self._records.get(family)
            if record is None or record["spent"]:
                return False
            record["spent"] = True
            return True

    def unspend(self, family: str) -> None:
        """Give the claim back after an approval that did not happen."""
        with self._lock:
            record = self._records.get(family)
            if record is not None:
                record["spent"] = False

    def clear(self) -> None:
        with self._lock:
            self._records.clear()


claims = PairClaims()
