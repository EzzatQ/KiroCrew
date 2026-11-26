"""The owner's list of waiting pairing requests and a device cancelling its own.

``GET /v1/crew/owner/device-approvals`` with no ``user_code`` lists what waits.
``POST /oauth/revoke`` with a device code cancels that request (RFC 7009 reused: the
secret code is the whole credential). Same middleware chain as
``test_device_pairing_routes.py``.
"""

from __future__ import annotations

import pytest
import test_device_pairing_routes as base
from test_device_pairing_routes import (
    LAN_HOST,
    PHONE,
    PHONE_HEADERS,
    _approve,
    _ask,
    _owner_cookie,
    _pair,
    _poll,
)

client = base.client
clock = base.clock

URL = "/v1/crew/owner/device-approvals"


async def _list(client, headers=None):
    return await client.get(URL, headers=headers or _owner_cookie())


async def _cancel(client, device_code: str, headers=None):
    return await client.post(
        "/oauth/revoke", data={"token": device_code}, headers=headers or PHONE_HEADERS
    )


@pytest.mark.asyncio
async def test_the_list_is_empty_then_oldest_first_with_the_codes(client, clock) -> None:
    empty = await _list(client)
    assert empty.status == 200
    assert (await empty.json())["data"] == []
    first = await _ask(client)
    clock.now += 10
    second = await _ask(client)
    clock.now += 5
    body = await (await _list(client)).json()
    assert body["object"] == "list" and body["has_more"] is False
    assert [r["user_code"] for r in body["data"]] == [first["user_code"], second["user_code"]]
    row = body["data"][0]
    assert row["object"] == "device_request"
    assert (row["device_name"], row["verified"], row["source_ip"]) == (
        "Alex's iPhone",
        False,
        PHONE,
    )
    assert (row["age"], row["expires_in"], row["via_tunnel"]) == (15, 285, False)


@pytest.mark.asyncio
async def test_answered_and_expired_requests_leave_the_list(client, clock) -> None:
    approved = await _ask(client)
    denied = await _ask(client)
    assert (await _approve(client, approved["user_code"])).status == 200
    assert (await _approve(client, denied["user_code"], approve=False)).status == 200
    assert (await (await _list(client)).json())["data"] == []
    await _ask(client)
    clock.now += 301
    assert (await (await _list(client)).json())["data"] == []


@pytest.mark.asyncio
async def test_only_the_host_owner_reads_the_list(client) -> None:
    await _ask(client)
    teammate = await _list(client, _owner_cookie("U_OTHER"))
    assert teammate.status == 403
    assert (await teammate.json())["error"]["code"] == "owner_only"
    anonymous = await _list(client, {"Host": LAN_HOST})
    assert anonymous.status in (401, 403)


@pytest.mark.asyncio
async def test_listing_has_its_own_budget_and_never_uses_up_the_answers(client) -> None:
    asked = await _ask(client)
    statuses = [(await _list(client)).status for _ in range(31)]
    assert statuses[:30] == [200] * 30 and statuses[30] == 429
    assert (await _approve(client, asked["user_code"])).status == 200


@pytest.mark.asyncio
async def test_a_lookup_by_code_still_answers_the_one_request(client) -> None:
    asked = await _ask(client)
    one = await client.get(URL, params={"user_code": asked["user_code"]}, headers=_owner_cookie())
    assert (await one.json())["object"] == "device_request"


@pytest.mark.asyncio
async def test_the_device_cancels_its_waiting_request(client) -> None:
    asked = await _ask(client)
    assert (await _cancel(client, asked["device_code"])).status == 200
    assert (await (await _list(client)).json())["data"] == []
    gone = await _approve(client, asked["user_code"])
    assert gone.status == 404
    poll = await _poll(client, asked["device_code"])
    assert (poll.status, (await poll.json())["error"]) == (400, "invalid_grant")
    rows = [c.kwargs for c in client.audit.log_api_access.call_args_list]
    assert any(
        r["operation"] == "local_auth.device_cancel" and r["outcome"] == "cancelled" for r in rows
    )


@pytest.mark.asyncio
async def test_cancelling_after_approval_blocks_the_redemption(client) -> None:
    asked = await _ask(client)
    assert (await _approve(client, asked["user_code"])).status == 200
    assert (await _cancel(client, asked["device_code"])).status == 200
    poll = await _poll(client, asked["device_code"])
    assert (await poll.json())["error"] == "invalid_grant"


@pytest.mark.asyncio
async def test_cancelling_leaves_a_redeemed_code_and_its_grant_alone(client) -> None:
    tokens = await _pair(client)
    asked = await _ask(client)
    other = await _cancel(client, asked["device_code"].replace("dc_", "dc_x", 1))
    assert other.status == 200  # an unknown code answers like a known one (RFC 7009)
    assert (await _list(client)).status == 200
    assert (await _approve(client, asked["user_code"])).status == 200
    assert tokens["refresh_token"]


@pytest.mark.asyncio
async def test_a_wrong_code_cancels_nothing_and_says_nothing(client) -> None:
    asked = await _ask(client)
    unknown = await _cancel(client, "dc_" + "x" * 43)
    assert unknown.status == 200 and await unknown.text() == ""
    assert len((await (await _list(client)).json())["data"]) == 1
    assert asked["user_code"]


@pytest.mark.asyncio
async def test_a_page_cannot_cancel(client) -> None:
    asked = await _ask(client)
    for hostile in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
        out = await _cancel(client, asked["device_code"], {"Host": LAN_HOST, **hostile})
        assert out.status == 403
    assert len((await (await _list(client)).json())["data"]) == 1


@pytest.mark.asyncio
async def test_a_relayed_caller_cannot_cancel(client) -> None:
    asked = await _ask(client)
    out = await _cancel(client, asked["device_code"], {**PHONE_HEADERS, "X-Test-Relay": "1"})
    assert out.status == 404
    assert len((await (await _list(client)).json())["data"]) == 1
