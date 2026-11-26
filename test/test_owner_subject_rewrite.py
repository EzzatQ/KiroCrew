"""A pre-owner bootstrap session acts as the owner once an owner is configured.

A token minted before ``owner_id`` existed carries ``local-app`` /
``local-startup`` for life. When it also carries the signed ``owner_mint`` claim
and the gateway now has an owner, the middleware sets ``request["user"]`` to
that owner in all three auth branches (query link, loopback cookie on a mixed
path, non-loopback cookie on a mixed path). Nothing else widens: no claim, an
app token, a teammate subject and an unset owner keep what they had.
"""

from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest
from aiohttp import web
from aiohttp.test_utils import make_mocked_request
from token_auth_helpers import clear_nonces  # noqa: F401 -- autouse fixture

from kiro_crew.dashboard.token_auth import generate_token, token_auth_middleware
from kiro_crew.dashboard.token_auth_tokens import bind_token_ip, mark_consumed, owner_mint_extra

OWNER = "U_OWNER"
MIXED = frozenset({"/api/mx"})


def _session(subject: str, *, mint: bool, link: bool = False) -> str:
    return generate_token(
        subject,
        ttl_seconds=300,
        register_nonce=link,
        session=not link,
        extra=owner_mint_extra() if mint else None,
    )


async def _seen_user(
    subject: str, *, branch: str, mint: bool = True, owner_id: str = OWNER
) -> str | None:
    """Run the middleware on one request; return the user a handler would see."""
    token = _session(subject, mint=mint, link=branch == "query")
    app = web.Application()
    app["state"] = SimpleNamespace(owner_id=owner_id)
    mw = token_auth_middleware(mixed_internal_paths=MIXED, port=5476)
    seen: dict = {}

    async def handler(request):
        seen["user"] = request.get("user")
        return web.Response(text="ok")

    transport = MagicMock()
    remote = "127.0.0.1" if branch != "cookie_remote" else "10.0.0.1"
    transport.get_extra_info.side_effect = lambda k, d=None: (
        (remote, 4000) if k == "peername" else d
    )
    if branch == "query":
        req = make_mocked_request("GET", f"/api/other?token={token}", app=app, transport=transport)
    else:
        req = make_mocked_request(
            "GET",
            "/api/mx",
            headers={"Cookie": f"mc_token_5476={token}"},
            app=app,
            transport=transport,
        )
        bind_token_ip(token, remote)
        mark_consumed(token)
    resp = await mw(req, handler)
    assert resp.status == 200, resp.text
    return seen.get("user")


BRANCHES = ["query", "cookie_loopback", "cookie_remote"]


@pytest.mark.asyncio
@pytest.mark.parametrize("branch", BRANCHES)
@pytest.mark.parametrize("subject", ["local-app", "local-startup"])
async def test_bootstrap_subject_with_owner_mint_acts_as_owner(branch, subject) -> None:
    assert await _seen_user(subject, branch=branch) == OWNER


@pytest.mark.asyncio
@pytest.mark.parametrize("branch", BRANCHES)
async def test_no_owner_mint_claim_keeps_the_subject(branch) -> None:
    assert await _seen_user("local-app", branch=branch, mint=False) == "local-app"


@pytest.mark.asyncio
@pytest.mark.parametrize("branch", BRANCHES)
async def test_no_configured_owner_keeps_the_subject(branch) -> None:
    assert await _seen_user("local-app", branch=branch, owner_id="") == "local-app"


@pytest.mark.asyncio
@pytest.mark.parametrize("branch", BRANCHES)
@pytest.mark.parametrize("subject", ["tailnet:uid:5", "U_TEAMMATE"])
async def test_other_subjects_keep_theirs_even_with_owner_mint(branch, subject) -> None:
    assert await _seen_user(subject, branch=branch) == subject


def test_app_token_keeps_its_subject_even_with_owner_mint() -> None:
    from kiro_crew.dashboard.token_auth import _owner_subject

    req = SimpleNamespace(app={"state": SimpleNamespace(owner_id=OWNER)})
    tok = _session("local-app", mint=True)
    assert _owner_subject(req, "local-app", "app-x", tok) == "local-app"  # type: ignore[arg-type]
    assert _owner_subject(req, "local-app", "", tok) == OWNER  # type: ignore[arg-type]
