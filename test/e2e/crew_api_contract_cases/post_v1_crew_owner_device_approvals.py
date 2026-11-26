"""``POST /v1/crew/owner/device-approvals``."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from e2e.crew_api_contract_spec import APP, OWNER, Case


def _pending(gateway: Any) -> dict[str, str]:
    return {"user_code": gateway.pending_device_code()}


def _answered(status: str) -> Callable[[Any], None]:
    def check(body: Any) -> None:
        assert body["status"] == status, body
        assert body["verified"] is False, body

    return check


CASES = [
    Case(
        "the owner approves a pairing request by its code",
        OWNER,
        200,
        json=_pending,
        check=_answered("approved"),
    ),
    Case(
        "the owner denies a pairing request by its code",
        OWNER,
        200,
        json=lambda gateway: {**_pending(gateway), "approve": False},
        check=_answered("denied"),
    ),
    Case(
        "a body without a code is refused",
        OWNER,
        400,
        "invalid_request",
        json={"approve": True},
    ),
    Case(
        "a code nobody was given is not found",
        OWNER,
        404,
        "not_found",
        json={"user_code": "BBBB-BBBB"},
    ),
    Case(
        "an app is refused on an Owner route",
        APP,
        403,
        "owner_only",
        json={"user_code": "BBBB-BBBB"},
    ),
]
