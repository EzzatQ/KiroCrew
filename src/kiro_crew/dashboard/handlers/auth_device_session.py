"""``POST /api/auth/device-session``: a paired device opens the dashboard.

A device holds a device grant (``local_authorization``, RFC 8628). It refreshes that
grant at ``/oauth/token`` for a 5-minute access token and sends it here as a Bearer
token. The handler checks it with :meth:`LocalAuthorization.verify_device` and answers
with the dashboard's own cookie pair: a 20-hour access cookie and a 30-day rotating
refresh cookie, set for the ``Host`` the app called, so the app calls it once for each
origin it loads. The cookie chain then refreshes itself at ``/api/auth/refresh`` like a
browser's.

The route reads no cookie, and the global CSRF check does not run for it
(``token_auth_paths.CSRF_EXEMPT_EXACT_METHODS``); a request that carries an ``Origin`` is
held to the allowlist here instead. A relayed caller is refused.

What the session is:

* The subject is the owner's id with the ``owner_mint`` claim, so Owner-tier routes accept
  it. Only the device's owner can have approved the pairing.
* It has no ``boot`` claim: a gateway restart does not end it.
* Its family is the grant id, so revoking the grant ends the cookie chain at once
  (``token_auth_tokens.revoke_family_id``), and a mint that races a revoke is refused by
  the family check made right before it.
* It is not pinned to a peer. The middleware pins the first access cookie it sees to its
  address; a device that changes address meets 403 ``IP mismatch`` and exchanges again.
"""

from __future__ import annotations

import asyncio
import logging
import time

from aiohttp import web

from kiro_crew.dashboard import local_authorization as la
from kiro_crew.dashboard.device_rate_limit import SlidingWindowLimiter
from kiro_crew.dashboard.handlers.auth_refresh import _set_access_cookie, _set_refresh_cookie
from kiro_crew.dashboard.kiro_relay.caller import published_relay_caller
from kiro_crew.dashboard.origin import (
    check_origin,
    is_entry_request,
    is_proxied_request,
    is_ssm_request,
)
from kiro_crew.dashboard.refresh_tokens import MAX_REFRESH_TTL_SECS, generate_refresh_token
from kiro_crew.dashboard.token_auth import (
    FAMILY_STATE_UNAVAILABLE,
    MAX_SESSION_TTL_SECS,
    credential_family_refusal,
    generate_token,
)
from kiro_crew.dashboard.token_auth_tokens import FAMILY_CLAIM, owner_mint_extra
from kiro_crew.sel import sel

logger = logging.getLogger(__name__)

_NO_STORE = {"Cache-Control": "no-store"}
#: Exchanges per minute and source. Behind a tunnel every caller is one source.
_LIMIT = SlidingWindowLimiter(30)
_BEARER_PREFIX = "bearer "
#: Without an owner id the dashboard's own bootstrap subject is the owner's.
_BOOTSTRAP_OWNER = "local-app"


def _bearer(request: web.Request) -> str:
    header = request.headers.get("Authorization", "")
    if header[: len(_BEARER_PREFIX)].lower() != _BEARER_PREFIX:
        return ""
    return header[len(_BEARER_PREFIX) :].strip()


def _error(status: int, code: str, message: str) -> web.Response:
    headers = dict(_NO_STORE)
    if status == 401:
        headers["WWW-Authenticate"] = 'Bearer error="invalid_token"'
    return web.json_response({"error": message, "code": code}, status=status, headers=headers)


async def _audit(outcome: str, grant_id: str = "") -> None:
    """Best-effort row. Only the grant id: a device's name is the device's own text."""

    def write() -> None:
        sel().log_api_access(
            caller="device-client",
            forwarded=False,
            operation="device_session",
            outcome=outcome,
            source="token_auth",
            resources=f"grant={grant_id}" if grant_id else "grant=none",
        )

    try:
        await asyncio.to_thread(write)
    except Exception:
        logger.warning("device-session audit failed")


async def api_auth_device_session(request: web.Request) -> web.Response:
    """Exchange a device access token for the dashboard cookie pair."""
    if (
        published_relay_caller(request) is not None
        or is_entry_request(request)
        or is_ssm_request(request)
    ):
        return _error(404, "not_found", "not served here")
    fetch_site = request.headers.get("Sec-Fetch-Site", "").lower()
    if fetch_site in ("cross-site", "same-site") or (
        "Origin" in request.headers and not check_origin(request, require=False)
    ):
        return _error(403, "forbidden_origin", "this address is for the app, not for a page")
    key = "fwd:" + (request.remote or "") if is_proxied_request(request) else request.remote or ""
    if _LIMIT.limited(key):
        return _error(429, "rate_limited", "too many sign-ins")
    token = _bearer(request)
    credential = (
        await asyncio.to_thread(
            lambda: la.gateway_local_authorization().verify_device(token),
        )
        if token and len(token) <= la.PRESENTED_MAX
        else None
    )
    if credential is None:
        await _audit("denied")
        return _error(401, "invalid_token", "the device token is missing, expired or revoked")
    grant_id = credential.grant_id
    refusal = credential_family_refusal(grant_id, "")
    if refusal == FAMILY_STATE_UNAVAILABLE:
        return _error(503, "revocation_state_unavailable", "revocations cannot be read")
    if refusal:
        await _audit("revoked", grant_id)
        return _error(401, "invalid_token", "the device token is missing, expired or revoked")
    owner = str(getattr(request.app["state"], "owner_id", "") or "") or _BOOTSTRAP_OWNER
    # Nothing between the family check above and the two mints below awaits, so no pair
    # outlives a revocation that was recorded before this point.
    access_token = generate_token(
        owner,
        ttl_seconds=MAX_SESSION_TTL_SECS,
        register_nonce=False,
        session=True,
        extra=owner_mint_extra({FAMILY_CLAIM: grant_id}),
    )
    refresh_token, _chain, _jti, refresh_exp = generate_refresh_token(
        owner, ttl_seconds=MAX_REFRESH_TTL_SECS, owner_mint=True, family=grant_id
    )
    session_exp = time.time() + MAX_SESSION_TTL_SECS
    resp = web.json_response(
        {"session_exp": session_exp, "refresh_exp": refresh_exp}, headers=_NO_STORE
    )
    _set_access_cookie(resp, request, access_token, session_exp)
    _set_refresh_cookie(resp, request, refresh_token, refresh_exp)
    await _audit("ok", grant_id)
    return resp
