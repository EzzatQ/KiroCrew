"""Scan once = signed in + paired.

The owner asks for a mobile link with ``pair: true``; the session that link becomes may
answer ONE pairing request: made within the window after the link redeemed, from the
address that redeemed it. Without the claim nothing changes. Runs through the same
middleware chain as ``test_device_pairing_routes.py``.
"""

from __future__ import annotations

from typing import Any

import pytest
import test_device_pairing_routes as base
from test_device_pairing_routes import (
    COOKIE,
    LAN_HOST,
    OWNER,
    PHONE,
    _ask,
)

from kiro_crew.dashboard import device_pair_claim as pair
from kiro_crew.dashboard.token_auth import generate_token
from kiro_crew.dashboard.token_auth_tokens import owner_mint_extra

OTHER = "192.168.1.99"

# The harness fixtures, bound under their own names so a test takes them by parameter.
client = base.client
clock = base.clock


@pytest.fixture(autouse=True)
def _claims(clock, monkeypatch):
    monkeypatch.setattr(pair.claims, "_clock", clock)
    pair.claims.clear()
    yield
    pair.claims.clear()


def _link(*, user: str = OWNER, claim: bool = True, owner: bool = True) -> str:
    extra: dict[str, str] = dict(owner_mint_extra()) if owner else {}
    if claim:
        extra[pair.PAIR_CLAIM] = "1"
    return generate_token(user, ttl_seconds=3600, extra=extra or None)


async def _redeem(client, link: str, peer: str = PHONE) -> dict[str, str]:
    """Open the link as the phone would; the headers of the session it gets."""
    resp = await client.get(
        "/ping", params={"token": link}, headers={"X-Test-Peer": peer, "Host": LAN_HOST}
    )
    assert resp.status == 200, await resp.text()
    cookie = resp.cookies[COOKIE].value
    return {
        "Cookie": f"{COOKIE}={cookie}",
        "Host": LAN_HOST,
        "X-Test-Peer": peer,
        "Origin": f"http://{LAN_HOST}",
    }


async def _answer(client, session: dict[str, str], code: str, approve: bool = True):
    return await client.post(
        "/v1/crew/owner/device-approvals",
        json={"user_code": code, "approve": approve},
        headers=session,
    )


async def _paired_session(client, **kw) -> tuple[dict[str, str], dict[str, Any]]:
    session = await _redeem(client, _link(**kw))
    return session, await _ask(client)


def _code(body: dict[str, Any]) -> str:
    return str(body["error"]["code"])


@pytest.mark.asyncio
async def test_happy_path_one_scan_approves_the_request_and_audits_it(
    client, clock, monkeypatch
) -> None:
    monkeypatch.setattr("kiro_crew.sel.sel", lambda: client.audit)
    session, asked = await _paired_session(client)
    clock.now += 30
    looked = await client.get(
        "/v1/crew/owner/device-approvals", params={"user_code": asked["user_code"]}, headers=session
    )
    assert looked.status == 200, await looked.text()
    resp = await _answer(client, session, asked["user_code"])
    assert resp.status == 200, await resp.text()
    assert (await resp.json())["status"] == "approved"
    rows = [c.kwargs for c in client.audit.log_api_access.call_args_list]
    row = next(r for r in rows if r["operation"] == "local_auth.device_pair_once")
    assert row["caller"] == OWNER and row["outcome"] == "approved"
    assert f"ip={PHONE}" in row["resources"] and asked["user_code"] not in row["resources"]


@pytest.mark.asyncio
async def test_second_use_is_refused_even_for_a_fresh_request(client) -> None:
    session, first = await _paired_session(client)
    assert (await _answer(client, session, first["user_code"])).status == 200
    second = await _ask(client)
    resp = await _answer(client, session, second["user_code"])
    assert (resp.status, _code(await resp.json())) == (403, pair.SPENT)


@pytest.mark.asyncio
async def test_a_request_made_after_the_window_is_refused(client, clock) -> None:
    session = await _redeem(client, _link())
    clock.now += pair.PAIR_WINDOW_SECS + 1
    asked = await _ask(client)
    resp = await _answer(client, session, asked["user_code"])
    assert (resp.status, _code(await resp.json())) == (403, pair.TOO_LATE)


@pytest.mark.asyncio
async def test_a_request_made_before_the_link_redeemed_is_refused(client, clock) -> None:
    asked = await _ask(client)
    clock.now += 5
    session = await _redeem(client, _link())
    resp = await _answer(client, session, asked["user_code"])
    assert (resp.status, _code(await resp.json())) == (403, pair.TOO_EARLY)


@pytest.mark.asyncio
async def test_a_request_from_another_address_is_refused(client) -> None:
    session = await _redeem(client, _link())
    other = await client.post(
        "/oauth/device_authorization",
        data={"client_id": "kirocrew-ios", "client_name": "Other"},
        headers={"X-Test-Peer": OTHER, "Host": LAN_HOST},
    )
    code = (await other.json())["user_code"]
    resp = await _answer(client, session, code)
    assert (resp.status, _code(await resp.json())) == (403, pair.WRONG_ADDRESS)


@pytest.mark.asyncio
async def test_a_session_on_another_address_than_the_redemption_is_refused(client) -> None:
    """The claim holder calls from an address other than the one that redeemed."""
    session, asked = await _paired_session(client)
    # The pinned session cannot move; a copy of the cookie from elsewhere is refused
    # by the session pin or by the address check, and nothing is approved.
    moved = {**session, "X-Test-Peer": OTHER}
    resp = await _answer(client, moved, asked["user_code"])
    assert resp.status in (401, 403)


@pytest.mark.asyncio
async def test_a_tunnel_hides_the_address_so_the_claim_refuses(client) -> None:
    link = _link()
    tunnel = {
        "Host": "localhost:5476",
        "X-Forwarded-For": "203.0.113.9",
        "X-Forwarded-Proto": "https",
        "X-Forwarded-Host": "kirocrew.tunnel.example.com",
    }
    resp = await client.get("/ping", params={"token": link}, headers=tunnel)
    assert resp.status == 200
    session = {
        "Cookie": f"{COOKIE}={resp.cookies[COOKIE].value}",
        "Origin": "https://kirocrew.tunnel.example.com",
        **tunnel,
    }
    asked = await _ask(client)
    out = await _answer(client, session, asked["user_code"])
    assert (out.status, _code(await out.json())) == (403, pair.NO_ADDRESS)


@pytest.mark.asyncio
async def test_a_session_without_the_claim_behaves_as_before(client) -> None:
    session = await _redeem(client, _link(claim=False))
    asked = await _ask(client)
    resp = await _answer(client, session, asked["user_code"])
    assert resp.status == 200
    again = await _ask(client)
    assert (await _answer(client, session, again["user_code"])).status == 200


@pytest.mark.asyncio
async def test_a_teammate_with_the_claim_is_still_refused(client) -> None:
    session = await _redeem(client, _link(user="U_TEAMMATE", owner=False))
    asked = await _ask(client)
    resp = await _answer(client, session, asked["user_code"])
    assert (resp.status, _code(await resp.json())) == (403, "owner_only")


@pytest.mark.asyncio
async def test_a_claim_session_may_deny_without_spending_the_claim(client) -> None:
    session, asked = await _paired_session(client)
    assert (await _answer(client, session, asked["user_code"], approve=False)).status == 200
    again = await _ask(client)
    assert (await _answer(client, session, again["user_code"])).status == 200


@pytest.mark.asyncio
async def test_a_failed_approval_gives_the_claim_back(client) -> None:
    session, asked = await _paired_session(client)
    missing = await _answer(client, session, "ZZZZ-ZZZZ")
    assert missing.status == 404
    assert (await _answer(client, session, asked["user_code"])).status == 200


@pytest.mark.asyncio
async def test_the_claim_is_not_inherited_by_a_refresh_cookie(client) -> None:
    session = await _redeem(client, _link())
    token = session["Cookie"].split("=", 1)[1]
    assert pair.claim_family({"auth_token": token}) != ""  # type: ignore[arg-type]
    resp = await client.get(
        "/ping", params={"token": _link()}, headers={"X-Test-Peer": PHONE, "Host": LAN_HOST}
    )
    refresh = [m.value for n, m in resp.cookies.items() if n.startswith("mc_refresh_")]
    assert refresh and all("device_pair" not in _decoded(v) for v in refresh)


def _decoded(token: str) -> str:
    from kiro_crew.dashboard.token_auth import _b64url_decode

    return _b64url_decode(token.split(".")[0]).decode("utf-8", "replace")


def test_the_claim_lifetime_ends_on_its_own_clock(clock) -> None:
    claims = pair.PairClaims(clock)
    claims.redeemed("fam", PHONE)
    now = int(clock.now)
    assert claims.refusal("fam", created_at=now, source=PHONE) == ""
    clock.now += pair.PAIR_CLAIM_TTL_SECS
    assert claims.refusal("fam", created_at=now, source=PHONE) == pair.EXPIRED


def test_only_the_first_redemption_counts(clock) -> None:
    claims = pair.PairClaims(clock)
    claims.redeemed("fam", PHONE)
    claims.redeemed("fam", OTHER)
    assert claims.refusal("fam", created_at=int(clock.now), source=OTHER) == pair.WRONG_ADDRESS


def test_two_racing_approvals_let_one_win(clock) -> None:
    claims = pair.PairClaims(clock)
    claims.redeemed("fam", PHONE)
    assert [claims.spend("fam"), claims.spend("fam")] == [True, False]


# ── the mint: POST /api/auth/mobile-link {"pair": true} ─────────────────────


@pytest.fixture
def mint_app(monkeypatch):
    from unittest.mock import MagicMock

    from aiohttp import web

    from kiro_crew.dashboard.handlers import auth_mobile

    @web.middleware
    async def identity(request, handler):
        request["user"] = request.headers.get("X-Test-User", OWNER)
        request["app"] = ""
        request["auth_token"] = request.headers.get("X-Test-Token", "")
        return await handler(request)

    monkeypatch.setattr(auth_mobile, "mint_denied_reason", lambda method: "")
    monkeypatch.setattr(auth_mobile, "_audit", lambda *a, **k: None)
    app = web.Application(middlewares=[identity])
    state = MagicMock()
    state.owner_id = OWNER
    app["state"] = state
    app["dashboard_url"] = "https://dash.example"
    app["allowed_origins"] = set()
    app["port"] = 5476
    app.router.add_post("/api/auth/mobile-link", auth_mobile.api_auth_mobile_link)
    return app


async def _mint(app, body: Any = None, *, user: str = OWNER, token: str | None = None):
    from aiohttp.test_utils import TestClient, TestServer

    headers = {"X-Test-User": user, "X-Test-Token": token or _link(claim=False)}
    async with TestClient(TestServer(app)) as c:
        resp = await c.post("/api/auth/mobile-link", json=body, headers=headers)
        return resp.status, await resp.json()


def _claims_of(payload: dict[str, Any]) -> dict[str, Any]:
    import json

    from kiro_crew.dashboard.token_auth import _b64url_decode

    return json.loads(_b64url_decode(payload["url"].split("token=", 1)[1].split(".")[0]))


@pytest.mark.asyncio
async def test_pair_true_mints_a_link_with_the_claim(mint_app) -> None:
    status, body = await _mint(mint_app, {"pair": True})
    assert status == 200 and body["pair"] is True
    assert _claims_of(body)[pair.PAIR_CLAIM] == "1"


@pytest.mark.asyncio
@pytest.mark.parametrize("sent", [None, {}, {"pair": False}, {"pair": "yes"}, {"pair": 1}])
async def test_an_ordinary_mint_has_no_claim(mint_app, sent) -> None:
    status, body = await _mint(mint_app, sent)
    assert status == 200 and "pair" not in body
    assert pair.PAIR_CLAIM not in _claims_of(body)


@pytest.mark.asyncio
async def test_a_teammate_cannot_ask_for_a_pair_link(mint_app) -> None:
    status, body = await _mint(mint_app, {"pair": True}, user="U_TEAMMATE")
    assert (status, body["code"]) == (403, "owner_only")


@pytest.mark.asyncio
async def test_a_claim_session_lends_a_link_without_the_claim(mint_app) -> None:
    status, body = await _mint(mint_app, None, token=_link())
    assert status == 200
    assert pair.PAIR_CLAIM not in _claims_of(body)


@pytest.mark.asyncio
async def test_an_approval_that_fails_after_the_check_gives_the_claim_back(
    client, monkeypatch
) -> None:
    from kiro_crew.dashboard import local_authorization as la

    session, asked = await _paired_session(client)
    real = client.store.decide_device
    calls: list[int] = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) == 1:
            raise la.UnknownRequest("device request")
        return real(*args, **kwargs)

    monkeypatch.setattr(client.store, "decide_device", flaky)
    assert (await _answer(client, session, asked["user_code"])).status == 404
    assert (await _answer(client, session, asked["user_code"])).status == 200


@pytest.mark.asyncio
async def test_without_a_redemption_record_a_claim_session_is_refused(client) -> None:
    session, asked = await _paired_session(client)
    pair.claims.clear()  # a gateway restart
    resp = await _answer(client, session, asked["user_code"])
    assert (resp.status, _code(await resp.json())) == (403, pair.UNKNOWN)


@pytest.mark.asyncio
async def test_a_claim_session_lists_only_the_request_its_claim_may_answer(client) -> None:
    session = await _redeem(client, _link())
    mine = await _ask(client)
    await client.post(
        "/oauth/device_authorization",
        data={"client_id": "kirocrew-ios", "client_name": "Other"},
        headers={"X-Test-Peer": OTHER, "Host": LAN_HOST},
    )
    url = "/v1/crew/owner/device-approvals"
    seen = await (await client.get(url, headers=session)).json()
    assert [r["user_code"] for r in seen["data"]] == [mine["user_code"]]
