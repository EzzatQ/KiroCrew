"""``GET /v1/crew/owner/device-approvals``."""

from __future__ import annotations

from typing import Any

from e2e.crew_api_contract_spec import APP, OWNER, Case


def _looked_up(body: Any) -> None:
    assert body["object"] == "device_request", body
    assert body["verified"] is False, body


def _listed(body: Any) -> None:
    assert body["object"] == "list", body
    assert all(row["object"] == "device_request" and "user_code" in row for row in body["data"])


CASES = [
    Case(
        "the owner sees who asks before answering",
        OWNER,
        200,
        query=lambda gateway: {"user_code": gateway.pending_device_code()},
        check=_looked_up,
    ),
    Case(
        "no code lists the waiting requests",
        OWNER,
        200,
        check=lambda body: _listed(body),
    ),
    Case(
        "an empty code is refused",
        OWNER,
        400,
        "invalid_request",
        query={"user_code": ""},
    ),
    Case(
        "a code nobody was given is not found",
        OWNER,
        404,
        "not_found",
        query={"user_code": "BBBB-BBBB"},
    ),
    Case(
        "an app is refused on an Owner route",
        APP,
        403,
        "owner_only",
        query={"user_code": "BBBB-BBBB"},
    ),
]
