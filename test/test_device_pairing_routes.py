"""Device pairing through the gateway's own middleware chain (Host barrier, CSRF, token
auth) and routes: ``/oauth/device_authorization``, the device-code and refresh grants of
``/oauth/token``, ``/oauth/revoke``, ``/api/auth/device-session`` and the owner's
``/v1/crew/owner/device-approvals``. The store rules are in
``test_device_pairing_store.py``.

A LAN phone is a request whose peer is ``192.168.1.14`` and whose ``Host`` names that
address; a same-host tunnel is a loopback peer with forwarding headers; the relay is a
published relay caller. ``X-Test-Peer`` and ``X-Test-Relay`` are the harness's stand-ins
for the socket and the relay ingress, set by the first middleware.
"""

from __future__ import annotations

import json
from typing import Any
from unittest.mock import Mock

import pytest
import pytest_asyncio
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from chat_test_helpers import _make_state
from test_local_authorization import ASK, Clock
from token_auth_helpers import clear_nonces  # noqa: F401 -- the autouse fixture registers by import

from kiro_crew.dashboard import local_authorization as la
from kiro_crew.dashboard import (  # noqa: F401 -- binds the names the middleware factories read
    server,
)
from kiro_crew.dashboard.handlers import auth_device_session as device_session
from kiro_crew.dashboard.handlers.auth_refresh import api_auth_refresh
from kiro_crew.dashboard.kiro_relay.caller import RELAY_CALLER_KEY, RelayCaller, RelayCallerKind
from kiro_crew.dashboard.refresh_tokens import (
    RefreshStateManager,
    refresh_cookie_name,
    refresh_token_boot,
    refresh_token_family,
)
from kiro_crew.dashboard.routes import crew_api
from kiro_crew.dashboard.routes import local_authorization as oauth_routes
from kiro_crew.dashboard.server_runtime.security_middleware import (
    _make_csrf_middleware,
    _make_host_validation_middleware,
)
from kiro_crew.dashboard.token_auth import (
    _b64url_decode,
    generate_token,
    revoke_all_sessions,
    token_auth_middleware,
)
from kiro_crew.dashboard.token_auth_paths import (
    CSRF_EXEMPT_EXACT_METHODS,
    _exact_method_bypass,
    is_csrf_exempt,
)
from kiro_crew.dashboard.token_auth_tokens import owner_mint_extra

OWNER = "U_OWNER"
PORT = 5476
LAN = "192.168.1.14"
LAN_HOST = f"{LAN}:{PORT}"
PHONE = "192.168.1.50"
FORM = {"Content-Type": "application/x-www-form-urlencoded"}
PHONE_HEADERS = {"X-Test-Peer": PHONE, "Host": LAN_HOST}
TUNNEL_HOST = "kirocrew.tunnel.example.com"
TUNNEL_HEADERS = {
    "Host": f"localhost:{PORT}",
    "X-Forwarded-For": "203.0.113.9",
    "X-Forwarded-Proto": "https",
    "X-Forwarded-Host": TUNNEL_HOST,
}
COOKIE = f"mc_token_{PORT}"


@web.middleware
async def _harness(request: web.Request, handler: Any) -> web.StreamResponse:
    if peer := request.headers.get("X-Test-Peer"):
        request = request.clone(remote=peer)
    if request.headers.get("X-Test-Relay"):
        request[RELAY_CALLER_KEY] = RelayCaller(
            kiro_user_id="kiro-user.x", kind=RelayCallerKind.OWNER
        )
    return await handler(request)


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest_asyncio.fixture
async def client(tmp_path, clock, monkeypatch):
    store = la.LocalAuthorization(tmp_path / "local-grants" / "state.json", b"k" * 32, clock)
    audit = Mock(spec=["log_api_access"])
    monkeypatch.setattr(la, "gateway_local_authorization", lambda: store)
    for module in (la, oauth_routes, device_session):
        monkeypatch.setattr(module, "sel", lambda: audit)
    monkeypatch.setattr(
        "kiro_crew.dashboard.refresh_tokens._state_singleton",
        RefreshStateManager(state_path=tmp_path / "refresh_chains.json"),
    )
    from kiro_crew.dashboard import crew_api_grant_requests

    for limiter in (
        crew_api_grant_requests._APPROVAL_LIMIT,
        crew_api_grant_requests._LIST_LIMIT,
        oauth_routes._PAIRING_LIMIT,
        oauth_routes._TOKEN_LIMIT,
        device_session._LIMIT,
    ):
        monkeypatch.setattr(limiter, "_calls", {})
    app = web.Application(
        middlewares=[
            _harness,
            _make_host_validation_middleware("dashboard_user"),
            _make_csrf_middleware("dashboard_user"),
            token_auth_middleware(port=PORT),
        ]
    )
    state = _make_state(tmp_path)
    state.owner_id = OWNER
    app["state"] = state
    app["port"] = PORT
    app["allowed_origins"] = {
        f"http://127.0.0.1:{PORT}",
        f"http://localhost:{PORT}",
        f"http://{LAN_HOST}",
        f"https://{TUNNEL_HOST}",
    }
    crew_api.register(app)
    oauth_routes.register(app)
    app.router.add_post("/api/auth/device-session", device_session.api_auth_device_session)
    app.router.add_post("/api/auth/refresh", api_auth_refresh)
    app.router.add_get("/ping", lambda request: web.json_response({"user": request.get("user")}))
    async with TestClient(TestServer(app)) as test_client:
        test_client.store = store
        test_client.audit = audit
        yield test_client


def _owner_cookie(user: str = OWNER) -> dict[str, str]:
    extra = owner_mint_extra() if user == OWNER else None
    token = generate_token(user, register_nonce=False, session=True, extra=extra)
    return {"Cookie": f"{COOKIE}={token}", "Host": LAN_HOST}


async def _ask(client, headers: dict[str, str] | None = None) -> dict[str, Any]:
    response = await client.post(
        "/oauth/device_authorization",
        data={"client_id": "kirocrew-ios", "client_name": "Alex's iPhone"},
        headers={**PHONE_HEADERS, **(headers or {})},
    )
    assert response.status == 200, await response.text()
    return await response.json()


async def _approve(client, user_code: str, approve: bool = True):
    return await client.post(
        "/v1/crew/owner/device-approvals",
        json={"user_code": user_code, "approve": approve},
        headers=_owner_cookie(),
    )


async def _poll(client, device_code: str, headers: dict[str, str] | None = None):
    client.store._clock.now += 5
    return await client.post(
        "/oauth/token",
        data={
            "grant_type": la.DEVICE_GRANT_TYPE,
            "client_id": "kirocrew-ios",
            "device_code": device_code,
        },
        headers={**PHONE_HEADERS, **(headers or {})},
    )


async def _pair(client) -> dict[str, Any]:
    asked = await _ask(client)
    assert (await _approve(client, asked["user_code"])).status == 200
    response = await _poll(client, asked["device_code"])
    assert response.status == 200
    return await response.json()


async def _exchange(client, tokens: dict[str, Any], headers: dict[str, str] | None = None):
    return await client.post(
        "/api/auth/device-session",
        headers={
            "Authorization": f"Bearer {tokens['access_token']}",
            **(headers or PHONE_HEADERS),
        },
    )


def _claims(token: str) -> dict[str, Any]:
    return json.loads(_b64url_decode(token.split(".")[0]))


# ── the four routes are open to a native app and closed to a page ──────────


def test_the_four_device_routes_skip_the_csrf_check_and_nothing_else_new_does():
    paths = {
        "/oauth/device_authorization",
        "/oauth/token",
        "/oauth/revoke",
        "/api/auth/device-session",
    }
    assert paths <= set(CSRF_EXEMPT_EXACT_METHODS)
    for path in paths:
        assert is_csrf_exempt(path, "POST") and not is_csrf_exempt(path, "PUT")
        assert not is_csrf_exempt(path, "GET")
    for path in ("/v1/crew/owner/device-approvals", "/oauth/authorize", "/api/auth/refresh"):
        assert not is_csrf_exempt(path, "POST")
    assert _exact_method_bypass("/oauth/device_authorization", "POST")
    assert _exact_method_bypass("/api/auth/device-session", "POST")
    assert not _exact_method_bypass("/api/auth/device-session", "GET")


@pytest.mark.asyncio
async def test_a_phone_on_the_lan_pairs_without_an_origin_header(client):
    asked = await _ask(client)
    assert set(asked) == {
        "device_code",
        "user_code",
        "expires_in",
        "interval",
        "verification_uri",
        "verification_uri_complete",
    }
    assert asked["verification_uri"] == f"http://{LAN_HOST}{oauth_routes.DEVICES_PAGE_PATH}"
    assert asked["verification_uri_complete"].endswith(f"?user_code={asked['user_code']}")
    assert asked["interval"] == 5 and asked["expires_in"] == 300


@pytest.mark.asyncio
async def test_a_browser_page_is_refused_on_each_device_route(client):
    tokens = await _pair(client)
    for path, form in (
        ("/oauth/device_authorization", {"client_id": "kirocrew-ios"}),
        ("/oauth/token", {"grant_type": "refresh_token", "client_id": "kirocrew-ios"}),
        ("/oauth/revoke", {"token": tokens["refresh_token"]}),
    ):
        for hostile in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
            response = await client.post(path, data=form, headers={**PHONE_HEADERS, **hostile})
            assert response.status == 403, (path, hostile)
    response = await client.post(
        "/api/auth/device-session",
        headers={
            "Authorization": f"Bearer {tokens['access_token']}",
            "Origin": "https://evil.example",
            **PHONE_HEADERS,
        },
    )
    assert response.status == 403
    # The grant is untouched by all of that.
    assert client.store.verify_device(tokens["access_token"]) is not None


@pytest.mark.asyncio
async def test_the_hosts_own_origin_is_not_a_browser_page(client):
    response = await client.post(
        "/oauth/device_authorization",
        data={"client_id": "kirocrew-ios"},
        headers={**PHONE_HEADERS, "Origin": f"http://{LAN_HOST}"},
    )
    assert response.status == 200


@pytest.mark.asyncio
async def test_the_host_barrier_still_runs_for_a_lan_caller(client):
    response = await client.post(
        "/oauth/device_authorization",
        data={"client_id": "kirocrew-ios"},
        headers={"X-Test-Peer": PHONE, "Host": "192.168.99.99:5476"},
    )
    assert response.status == 403


@pytest.mark.asyncio
async def test_the_relay_is_refused_on_every_device_route(client):
    tokens = await _pair(client)
    relay = {"X-Test-Relay": "1", "X-Test-Peer": "127.0.0.1"}
    for method, path, kwargs in (
        ("GET", "/.well-known/oauth-authorization-server", {}),
        ("POST", "/oauth/device_authorization", {"data": {"client_id": "kirocrew-ios"}}),
        (
            "POST",
            "/oauth/token",
            {"data": {"grant_type": "refresh_token", "client_id": "x", "refresh_token": "y"}},
        ),
        ("POST", "/oauth/revoke", {"data": {"token": tokens["refresh_token"]}}),
    ):
        response = await client.request(method, path, headers=relay, **kwargs)
        assert response.status == 404, path
    response = await client.post(
        "/api/auth/device-session",
        headers={"Authorization": f"Bearer {tokens['access_token']}", **relay},
    )
    assert response.status == 404


@pytest.mark.asyncio
async def test_the_metadata_names_the_device_endpoint_and_grant_for_a_lan_caller(client):
    response = await client.get("/.well-known/oauth-authorization-server", headers=PHONE_HEADERS)
    body = await response.json()
    assert response.status == 200
    assert body["device_authorization_endpoint"] == f"http://{LAN_HOST}/oauth/device_authorization"
    assert la.DEVICE_GRANT_TYPE in body["grant_types_supported"]
    assert body["token_endpoint"] == f"http://{LAN_HOST}/oauth/token"


# ── the whole flow ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_a_phone_pairs_refreshes_and_opens_the_dashboard_on_both_origins(client):
    tokens = await _pair(client)
    assert tokens["scope"] == "dashboard" and tokens["expires_in"] == 300
    refreshed = await client.post(
        "/oauth/token",
        data={
            "grant_type": "refresh_token",
            "client_id": "kirocrew-ios",
            "refresh_token": tokens["refresh_token"],
        },
        headers=PHONE_HEADERS,
    )
    assert refreshed.status == 200
    tokens = await refreshed.json()
    lan = await _exchange(client, tokens)
    assert lan.status == 200
    assert set(await lan.json()) == {"session_exp", "refresh_exp"}
    assert lan.headers["Cache-Control"] == "no-store"
    lan_access = lan.cookies[COOKIE].value
    lan_refresh = lan.cookies[refresh_cookie_name(PORT)].value
    assert not lan.cookies[COOKIE]["secure"]
    # The same 5-minute token opens the tunnel origin too, with a Secure cookie.
    tunnel = await _exchange(client, tokens, TUNNEL_HEADERS)
    assert tunnel.status == 200
    assert tunnel.cookies[COOKIE]["secure"]

    claims = _claims(lan_access)
    assert claims["sub"] == OWNER and claims["owner_mint"] == "1" and claims["kind"] == "session"
    assert claims["family"] == tokens["grant_id"] and "boot" not in claims
    assert refresh_token_boot(lan_refresh) == ""
    assert refresh_token_family(lan_refresh) == tokens["grant_id"]

    # The cookie is the owner's: the dashboard and the Owner tier accept it.
    ping = await client.get("/ping", headers={"Cookie": f"{COOKIE}={lan_access}", "Host": LAN_HOST})
    assert (await ping.json())["user"] == OWNER
    grants = await client.get(
        "/v1/crew/owner/grants", headers={"Cookie": f"{COOKIE}={lan_access}", "Host": LAN_HOST}
    )
    assert grants.status == 200
    [row] = (await grants.json())["data"]
    assert row["id"] == tokens["grant_id"] and row["kind"] == "device"
    assert row["last_ip"] == PHONE and row["scopes"] == ["dashboard"]
    # And its refresh cookie rotates like a browser's.
    rotated = await client.post(
        "/api/auth/refresh",
        headers={"Cookie": f"{refresh_cookie_name(PORT)}={lan_refresh}", "Host": LAN_HOST},
    )
    assert rotated.status == 200
    assert refresh_token_family(rotated.cookies[refresh_cookie_name(PORT)].value) == (
        tokens["grant_id"]
    )


@pytest.mark.asyncio
async def test_a_tunnel_caller_pairs_and_its_address_is_not_recorded(client):
    asked = await _ask(client, TUNNEL_HEADERS)
    assert asked["verification_uri"].startswith("http://localhost:")
    approved = await _approve(client, asked["user_code"])
    assert (await approved.json())["source_ip"] == ""
    response = await _poll(client, asked["device_code"], TUNNEL_HEADERS)
    assert response.status == 200


@pytest.mark.asyncio
async def test_polling_answers_the_rfc_errors_as_http_400(client):
    asked = await _ask(client)
    pending = await _poll(client, asked["device_code"])
    assert pending.status == 400 and (await pending.json())["error"] == "authorization_pending"
    early = await client.post(
        "/oauth/token",
        data={
            "grant_type": la.DEVICE_GRANT_TYPE,
            "client_id": "kirocrew-ios",
            "device_code": asked["device_code"],
        },
        headers=PHONE_HEADERS,
    )
    body = await early.json()
    assert early.status == 400 and body["error"] == "slow_down"
    assert early.headers["Retry-After"] == "10"
    client.store._clock.now += 20
    await _approve(client, asked["user_code"], approve=False)
    denied = await _poll(client, asked["device_code"])
    assert denied.status == 400 and (await denied.json())["error"] == "access_denied"


@pytest.mark.asyncio
async def test_the_code_flow_and_an_app_grant_stay_on_this_machine(client):
    response = await client.post(
        "/oauth/token",
        data={"grant_type": "authorization_code", "client_id": ASK["client_id"]},
        headers=PHONE_HEADERS,
    )
    assert response.status == 404
    response = await client.get("/oauth/authorize", params=ASK, headers=PHONE_HEADERS)
    assert response.status == 404
    response = await client.post(
        "/oauth/device_authorization", data={"client_id": "notely-desktop"}, headers=PHONE_HEADERS
    )
    assert response.status == 400 and (await response.json())["error"] == "unauthorized_client"


@pytest.mark.asyncio
async def test_pairing_requests_are_rate_limited_per_source(client):
    statuses = []
    for _ in range(12):
        response = await client.post(
            "/oauth/device_authorization",
            data={"client_id": "kirocrew-ios"},
            headers={"X-Test-Peer": PHONE, "Host": LAN_HOST},
        )
        statuses.append(response.status)
    assert 429 in statuses
    # The store's own cap of 3 waiting requests per source answers first.
    assert 503 in statuses


# ── the owner's side ───────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_the_owner_answers_with_a_device_summary_and_a_bad_code_is_a_404(client):
    asked = await _ask(client)
    response = await _approve(client, asked["user_code"])
    body = await response.json()
    assert response.status == 200
    assert body["object"] == "device_approval" and body["status"] == "approved"
    assert body["device_name"] == "Alex's iPhone" and body["verified"] is False
    assert body["source_ip"] == PHONE and body["client_id"] == "kirocrew-ios"
    for code in (asked["user_code"], "BBBB-BBBB"):
        again = await _approve(client, code)
        assert again.status == 404
        assert (await again.json())["error"]["code"] == "not_found"


@pytest.mark.asyncio
async def test_a_teammate_and_an_app_cannot_approve_and_a_foreign_origin_is_csrf_refused(client):
    asked = await _ask(client)
    body = {"user_code": asked["user_code"]}
    teammate = await client.post(
        "/v1/crew/owner/device-approvals", json=body, headers=_owner_cookie("U_OTHER")
    )
    assert teammate.status == 403
    foreign = await client.post(
        "/v1/crew/owner/device-approvals",
        json=body,
        headers={**_owner_cookie(), "Origin": "https://evil.example"},
    )
    assert foreign.status in (401, 403)
    anonymous = await client.post(
        "/v1/crew/owner/device-approvals", json=body, headers={"Host": LAN_HOST}
    )
    assert anonymous.status in (401, 403)
    # None of that approved it.
    assert (await _poll(client, asked["device_code"])).status == 400
    assert (await _approve(client, asked["user_code"])).status == 200


@pytest.mark.asyncio
async def test_approval_attempts_are_limited(client):
    statuses = [(await _approve(client, "BBBB-BBBB")).status for _ in range(12)]
    assert statuses.count(404) == 10 and statuses[-1] == 429


@pytest.mark.asyncio
async def test_a_malformed_approval_body_is_a_400(client):
    for body in ({}, {"user_code": 5}, {"user_code": "BBBB-BBBB", "approve": "yes"}):
        response = await client.post(
            "/v1/crew/owner/device-approvals", json=body, headers=_owner_cookie()
        )
        assert response.status == 400


# ── what a device credential is not ────────────────────────────────────────


@pytest.mark.asyncio
async def test_a_device_token_is_no_crew_api_credential_and_an_app_token_is_no_device_one(client):
    tokens = await _pair(client)
    bearer = {"Authorization": f"Bearer {tokens['access_token']}"}
    for path in ("/v1/crew/grant", "/v1/crew/owner/grants", "/v1/models"):
        response = await client.get(path, headers=bearer)
        assert response.status in (401, 403), path
    # A token this gateway signed for an app, or no token, opens no session.
    store = client.store
    kind, view = store.authorize(ASK)
    store.decide(view["request_id"], True, caller=OWNER)
    store._clock.now += la.POLL_INTERVAL_SECS
    _, location = store.authorize({**ASK, "request_id": view["request_id"]})
    from test_local_authorization import ISSUER, REDIRECT, VERIFIER

    app = store.exchange_code(
        ASK["client_id"], location.split("code=")[1].split("&")[0], REDIRECT, VERIFIER, ISSUER
    )
    for header in (f"Bearer {app['access_token']}", "Bearer ", "Bearer junk", "Basic abc", ""):
        response = await client.post(
            "/api/auth/device-session", headers={"Authorization": header, **PHONE_HEADERS}
        )
        assert response.status == 401, header
        assert response.headers["WWW-Authenticate"].startswith("Bearer")
        assert Cookie_free(response)


def Cookie_free(response) -> bool:
    return not response.cookies


@pytest.mark.asyncio
async def test_device_session_ignores_a_cookie_and_needs_the_bearer(client):
    response = await client.post("/api/auth/device-session", headers=_owner_cookie())
    assert response.status == 401


@pytest.mark.asyncio
async def test_an_expired_device_token_opens_nothing(client):
    tokens = await _pair(client)
    client.store._clock.now += la.ACCESS_TTL_SECS + 1
    assert (await _exchange(client, tokens)).status == 401


# ── revocation ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_revoking_in_the_ui_ends_the_grant_and_the_cookies_at_once(client):
    tokens = await _pair(client)
    session = await _exchange(client, tokens)
    access = session.cookies[COOKIE].value
    refresh = session.cookies[refresh_cookie_name(PORT)].value
    cookies = {"Cookie": f"{COOKIE}={access}", "Host": LAN_HOST}
    assert (await client.get("/ping", headers=cookies)).status == 200

    deleted = await client.delete(
        f"/v1/crew/owner/grants/{tokens['grant_id']}", headers=_owner_cookie()
    )
    assert deleted.status == 200

    assert (await client.get("/ping", headers=cookies)).status in (401, 403)
    rotated = await client.post(
        "/api/auth/refresh",
        headers={"Cookie": f"{refresh_cookie_name(PORT)}={refresh}", "Host": LAN_HOST},
    )
    assert rotated.status == 401
    assert (await _exchange(client, tokens)).status == 401
    refresh_again = await client.post(
        "/oauth/token",
        data={
            "grant_type": "refresh_token",
            "client_id": "kirocrew-ios",
            "refresh_token": tokens["refresh_token"],
        },
        headers=PHONE_HEADERS,
    )
    assert refresh_again.status == 400


@pytest.mark.asyncio
async def test_the_app_logging_out_ends_the_cookies_too_and_a_retry_is_safe(client):
    tokens = await _pair(client)
    session = await _exchange(client, tokens)
    cookies = {"Cookie": f"{COOKIE}={session.cookies[COOKIE].value}", "Host": LAN_HOST}
    for _ in range(2):
        revoked = await client.post(
            "/oauth/revoke", data={"token": tokens["refresh_token"]}, headers=PHONE_HEADERS
        )
        assert revoked.status == 200
    assert (await client.get("/ping", headers=cookies)).status in (401, 403)
    assert client.store.verify_device(tokens["access_token"]) is None


@pytest.mark.asyncio
async def test_a_remote_caller_cannot_revoke_an_app_grant(client):
    response = await client.post(
        "/oauth/revoke", data={"token": "lr_not-a-device"}, headers=PHONE_HEADERS
    )
    assert response.status == 404


@pytest.mark.asyncio
async def test_a_failed_cookie_revocation_is_reported_and_a_retry_finishes_it(client, monkeypatch):
    tokens = await _pair(client)
    import kiro_crew.dashboard.crew_api_grant_requests as grants

    def broken(_family):
        raise OSError("denylist unwritable")

    monkeypatch.setattr(grants, "revoke_family_id", broken)
    failed = await client.delete(
        f"/v1/crew/owner/grants/{tokens['grant_id']}", headers=_owner_cookie()
    )
    assert failed.status == 503
    assert (await failed.json())["error"]["code"] == "cookie_revocation_failed"
    assert client.store.verify_device(tokens["access_token"]) is None


@pytest.mark.asyncio
async def test_an_unreadable_revocation_store_is_a_503_not_a_session(client, monkeypatch):
    tokens = await _pair(client)
    monkeypatch.setattr(
        device_session,
        "credential_family_refusal",
        lambda *_: device_session.FAMILY_STATE_UNAVAILABLE,
    )
    response = await _exchange(client, tokens)
    assert response.status == 503 and not response.cookies


@pytest.mark.asyncio
async def test_a_revocation_that_lands_before_the_mint_is_refused(client):
    from kiro_crew.dashboard.token_auth_tokens import revoke_family_id

    tokens = await _pair(client)
    revoke_family_id(tokens["grant_id"])
    response = await _exchange(client, tokens)
    assert response.status == 401 and not response.cookies


@pytest.mark.asyncio
async def test_kirocrew_logout_ends_the_cookies_and_not_the_grant(client):
    tokens = await _pair(client)
    session = await _exchange(client, tokens)
    cookies = {"Cookie": f"{COOKIE}={session.cookies[COOKIE].value}", "Host": LAN_HOST}
    assert (await client.get("/ping", headers=cookies)).status == 200
    revoke_all_sessions()
    assert (await client.get("/ping", headers=cookies)).status in (401, 403)
    assert client.store.verify_device(tokens["access_token"]) is not None
    again = await _exchange(client, tokens)
    assert again.status == 200


@pytest.mark.asyncio
async def test_a_device_session_survives_a_gateway_restart(client, monkeypatch):
    tokens = await _pair(client)
    session = await _exchange(client, tokens)
    cookies = {"Cookie": f"{COOKIE}={session.cookies[COOKIE].value}", "Host": LAN_HOST}
    from kiro_crew.dashboard import boot_id

    monkeypatch.setattr(boot_id, "current_boot_id", lambda: "a-different-process")
    assert (await client.get("/ping", headers=cookies)).status == 200


@pytest.mark.asyncio
async def test_each_pairing_audits_its_grant_and_never_the_device_name(client):
    tokens = await _pair(client)
    await _exchange(client, tokens)
    rows = [call.kwargs for call in client.audit.log_api_access.call_args_list]
    device_rows = [row for row in rows if row["caller"] == "device-client"]
    assert {row["operation"] for row in device_rows} >= {
        "local_auth.device_request",
        "local_auth.token",
        "device_session",
    }
    assert "iPhone" not in json.dumps(rows)
    assert any(row["resources"] == f"grant={tokens['grant_id']}" for row in device_rows)


# ── review fixes ────────────────────────────────────────────────────────────


def _refresh_form(token: str) -> dict[str, str]:
    return {"grant_type": "refresh_token", "client_id": "kirocrew-ios", "refresh_token": token}


async def _cookie_pair(client, tokens: dict[str, Any]) -> tuple[dict[str, str], dict[str, str]]:
    """The dashboard access and refresh cookies a device exchange opened, as headers."""
    session = await _exchange(client, tokens)
    assert session.status == 200
    access = {"Cookie": f"{COOKIE}={session.cookies[COOKIE].value}", "Host": LAN_HOST}
    name = refresh_cookie_name(PORT)
    refresh = {"Cookie": f"{name}={session.cookies[name].value}", "Host": LAN_HOST}
    return access, refresh


async def _both_cookies_refused(client, access: dict[str, str], refresh: dict[str, str]) -> None:
    assert (await client.get("/ping", headers=access)).status in (401, 403)
    assert (await client.post("/api/auth/refresh", headers=refresh)).status == 401


@pytest.mark.asyncio
async def test_a_reused_refresh_token_revokes_the_grant_and_its_cookie_chain(client):
    tokens = await _pair(client)
    access, refresh = await _cookie_pair(client, tokens)
    assert (await client.get("/ping", headers=access)).status == 200
    rotated = await client.post(
        "/oauth/token", data=_refresh_form(tokens["refresh_token"]), headers=PHONE_HEADERS
    )
    assert rotated.status == 200
    client.store._clock.now += 60
    replay = await client.post(
        "/oauth/token", data=_refresh_form(tokens["refresh_token"]), headers=PHONE_HEADERS
    )
    assert replay.status == 400 and (await replay.json())["error"] == "invalid_grant"
    next_token = (await rotated.json())["refresh_token"]
    assert (
        await client.post("/oauth/token", data=_refresh_form(next_token), headers=PHONE_HEADERS)
    ).status == 400
    await _both_cookies_refused(client, access, refresh)


@pytest.mark.asyncio
async def test_a_device_code_redeemed_twice_revokes_the_grant_and_its_cookie_chain(client):
    asked = await _ask(client)
    assert (await _approve(client, asked["user_code"])).status == 200
    first = await _poll(client, asked["device_code"])
    assert first.status == 200
    tokens = await first.json()
    access, refresh = await _cookie_pair(client, tokens)
    second = await _poll(client, asked["device_code"])
    assert second.status == 400 and (await second.json())["error"] == "invalid_grant"
    assert client.store.verify_device(tokens["access_token"]) is None
    await _both_cookies_refused(client, access, refresh)
    # A repeat of the reused code finishes the cookie revoke as well.
    assert (await _poll(client, asked["device_code"])).status == 400


@pytest.mark.asyncio
async def test_a_failed_cookie_revoke_on_reuse_still_answers_invalid_grant(client, monkeypatch):
    tokens = await _pair(client)
    await client.post(
        "/oauth/token", data=_refresh_form(tokens["refresh_token"]), headers=PHONE_HEADERS
    )
    client.store._clock.now += 60
    import kiro_crew.dashboard.token_auth_tokens as token_tokens

    def broken(_family):
        raise OSError("denylist unwritable")

    monkeypatch.setattr(token_tokens, "revoke_family_id", broken)
    replay = await client.post(
        "/oauth/token", data=_refresh_form(tokens["refresh_token"]), headers=PHONE_HEADERS
    )
    assert replay.status == 400 and (await replay.json())["error"] == "invalid_grant"
    assert client.store.verify_device(tokens["access_token"]) is None


@pytest.mark.asyncio
async def test_a_browser_page_is_refused_on_every_grant_type_of_the_token_route(client):
    for form in (
        {"grant_type": "authorization_code", "client_id": ASK["client_id"]},
        {"grant_type": "nonsense", "client_id": "x"},
        {"grant_type": "refresh_token", "client_id": "x", "refresh_token": "y"},
    ):
        for hostile in ({"Origin": "https://evil.example"}, {"Sec-Fetch-Site": "cross-site"}):
            response = await client.post(
                "/oauth/token", data=form, headers={"Host": LAN_HOST, **hostile}
            )
            assert response.status == 403, (form["grant_type"], hostile)


@pytest.mark.asyncio
async def test_the_owner_looks_up_who_asks_before_answering(client):
    asked = await _ask(client)
    client.store._clock.now += 20
    looked = await client.get(
        "/v1/crew/owner/device-approvals",
        params={"user_code": asked["user_code"].lower()},
        headers=_owner_cookie(),
    )
    body = await looked.json()
    assert looked.status == 200
    assert body == {
        "object": "device_request",
        "client_id": "kirocrew-ios",
        "device_name": "Alex's iPhone",
        "verified": False,
        "source_ip": PHONE,
        "via_tunnel": False,
        "created_at": body["created_at"],
        "expires_at": body["expires_at"],
        "age": 20,
        "expires_in": 280,
    }
    # Looking up changes nothing: the request still waits, and the answer still works.
    assert (await _poll(client, asked["device_code"])).status == 400
    assert (await _approve(client, asked["user_code"])).status == 200


@pytest.mark.asyncio
async def test_a_tunnel_request_is_looked_up_as_via_tunnel(client):
    asked = await client.post(
        "/oauth/device_authorization", data={"client_id": "kirocrew-ios"}, headers=TUNNEL_HEADERS
    )
    code = (await asked.json())["user_code"]
    looked = await client.get(
        "/v1/crew/owner/device-approvals", params={"user_code": code}, headers=_owner_cookie()
    )
    body = await looked.json()
    assert looked.status == 200 and body["source_ip"] == "" and body["via_tunnel"] is True


@pytest.mark.asyncio
async def test_the_lookup_is_owner_only_limited_and_uniformly_404(client):
    asked = await _ask(client)
    url = "/v1/crew/owner/device-approvals"
    teammate = await client.get(
        url, params={"user_code": asked["user_code"]}, headers=_owner_cookie("U_OTHER")
    )
    assert teammate.status == 403
    anonymous = await client.get(
        url, params={"user_code": asked["user_code"]}, headers={"Host": LAN_HOST}
    )
    assert anonymous.status in (401, 403)
    # No code at all lists the waiting requests; an empty code is the 400.
    assert (await client.get(url, headers=_owner_cookie())).status == 200
    assert (await client.get(url, params={"user_code": ""}, headers=_owner_cookie())).status == 400
    assert (await _approve(client, asked["user_code"])).status == 200
    for code in (asked["user_code"], "BBBB-BBBB"):
        gone = await client.get(url, params={"user_code": code}, headers=_owner_cookie())
        assert gone.status == 404 and (await gone.json())["error"]["code"] == "not_found"
    statuses = [
        (await client.get(url, params={"user_code": "BBBB-BBBB"}, headers=_owner_cookie())).status
        for _ in range(12)
    ]
    assert statuses[-1] == 429


@pytest.mark.asyncio
async def test_a_refused_lookup_or_answer_leaves_an_audit_row_without_the_typed_text(client):
    typed = "ZZZZ-ZZZZ"
    await client.get(
        "/v1/crew/owner/device-approvals", params={"user_code": typed}, headers=_owner_cookie()
    )
    await _approve(client, typed)
    rows = [call.kwargs for call in client.audit.log_api_access.call_args_list]
    refused = [row for row in rows if row["outcome"] == "unknown_code"]
    assert {row["operation"] for row in refused} == {
        "local_auth.device_lookup",
        "local_auth.device_decide",
    }
    assert all(row["caller"] == OWNER for row in refused)
    assert typed not in json.dumps(rows)


@pytest.mark.asyncio
async def test_a_cookie_chain_stops_rotating_when_its_grant_ends(client):
    tokens = await _pair(client)
    _access, refresh = await _cookie_pair(client, tokens)
    # The grant ends without anyone writing the family denylist (an idle expiry).
    client.store._clock.now += la.DEVICE_REFRESH_IDLE_SECS + 1
    rotated = await client.post("/api/auth/refresh", headers=refresh)
    assert rotated.status == 401
    assert (await rotated.json())["code"] == "invalid_refresh"


@pytest.mark.asyncio
async def test_a_cookie_chain_stops_rotating_when_its_grant_is_revoked_in_the_store_alone(client):
    tokens = await _pair(client)
    _access, refresh = await _cookie_pair(client, tokens)
    client.store.revoke_grant(tokens["grant_id"], caller=OWNER)
    assert (await client.post("/api/auth/refresh", headers=refresh)).status == 401


@pytest.mark.asyncio
async def test_a_cookie_rotation_counts_as_use_at_most_every_ten_minutes(client):
    tokens = await _pair(client)
    _access, refresh = await _cookie_pair(client, tokens)
    paired_at = client.store.grant(tokens["grant_id"])["last_used_at"]
    client.store._clock.now += 60
    first = await client.post("/api/auth/refresh", headers=refresh)
    assert first.status == 200
    assert client.store.grant(tokens["grant_id"])["last_used_at"] == paired_at
    client.store._clock.now += la.DEVICE_TOUCH_SECS
    name = refresh_cookie_name(PORT)
    again = await client.post(
        "/api/auth/refresh",
        headers={"Cookie": f"{name}={first.cookies[name].value}", "Host": LAN_HOST},
    )
    assert again.status == 200
    assert client.store.grant(tokens["grant_id"])["last_used_at"] == int(client.store._clock.now)


@pytest.mark.asyncio
async def test_an_unreadable_grant_record_fails_the_cookie_rotation_closed(client, monkeypatch):
    tokens = await _pair(client)
    _access, refresh = await _cookie_pair(client, tokens)

    def broken(_grant_id):
        raise OSError("record unreadable")

    monkeypatch.setattr(client.store, "touch_device_session", broken)
    rotated = await client.post("/api/auth/refresh", headers=refresh)
    assert rotated.status == 503 and not rotated.cookies


@pytest.mark.asyncio
async def test_a_closed_lts_gate_serves_the_device_grants_of_the_token_route_alone(
    client, monkeypatch
):
    tokens = await _pair(client)
    monkeypatch.setattr(oauth_routes, "login_screen_required", lambda _app: True)
    refreshed = await client.post(
        "/oauth/token", data=_refresh_form(tokens["refresh_token"]), headers=PHONE_HEADERS
    )
    assert refreshed.status == 200
    asked = await _ask(client)
    assert (await _approve(client, asked["user_code"])).status == 200
    assert (await _poll(client, asked["device_code"])).status == 200
    local = {"Host": f"127.0.0.1:{PORT}"}
    for form in (
        {"grant_type": "authorization_code", "client_id": ASK["client_id"]},
        {"grant_type": "refresh_token", "client_id": "x", "refresh_token": "y"},
    ):
        closed = await client.post("/oauth/token", data=form, headers=local)
        assert closed.status == 403 and (await closed.json())["code"] == "lts_gate_closed"
