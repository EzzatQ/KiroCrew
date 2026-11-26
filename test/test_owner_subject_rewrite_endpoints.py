"""Owner-gated endpoints answer a rewritten bootstrap session as the owner.

Real token middleware + the real handlers. A ``local-app`` session carrying
``owner_mint`` (signed in before ``owner_id`` existed) now passes the owner
gate; a claimless one keeps the 401 relabel and a teammate keeps the 403.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from token_auth_helpers import clear_nonces  # noqa: F401 -- autouse fixture

from kiro_crew.dashboard import handlers_instances
from kiro_crew.dashboard.file_api import editor
from kiro_crew.dashboard.handlers import files, secrets
from kiro_crew.dashboard.handlers import source_providers as source
from kiro_crew.dashboard.token_auth import generate_token, token_auth_middleware
from kiro_crew.dashboard.token_auth_tokens import owner_mint_extra

OWNER = "U_OWNER"
ROUTES = [
    ("/api/file-raw", editor.api_file_raw),
    ("/api/file-read", editor.api_file_read),
    ("/api/browse-dirs", files.api_browse_dirs),
    ("/api/instances", handlers_instances.api_instances_list),
    ("/api/secrets", secrets.api_secrets_list),
]


@pytest.fixture(autouse=True)
def _quiet_audit(monkeypatch):
    monkeypatch.setattr(source, "_sel", lambda: MagicMock())
    monkeypatch.setattr(secrets, "_sel", lambda: MagicMock(), raising=False)
    monkeypatch.setattr(
        "kiro_crew.dashboard.handlers._shared_access._sel", lambda: MagicMock(), raising=False
    )


async def _status(path: str, handler, subject: str, *, mint: bool) -> tuple[int, dict]:
    app = web.Application(middlewares=[token_auth_middleware()])
    app["state"] = MagicMock(owner_id=OWNER)
    app.router.add_get(path, handler)
    tok = generate_token(subject, ttl_seconds=300, extra=owner_mint_extra() if mint else None)
    async with TestClient(TestServer(app)) as client:
        resp = await client.get(path, params={"token": tok, "path": "/nonexistent"})
        try:
            body = await resp.json()
        except Exception:
            body = {}
        return resp.status, body


def _owner_denied(status: int, body: dict) -> bool:
    return body.get("code") in {"owner_only", source.STALE_OWNER_SESSION_CODE} or (
        status in (401, 403) and body.get("error") == "owner authorization required"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "handler"), ROUTES)
async def test_rewritten_local_app_session_passes_the_owner_gate(path, handler) -> None:
    status, body = await _status(path, handler, "local-app", mint=True)
    assert not _owner_denied(status, body), (status, body)


@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "handler"), ROUTES)
async def test_claimless_local_app_session_keeps_the_stale_401(path, handler) -> None:
    status, body = await _status(path, handler, "local-app", mint=False)
    assert (status, body.get("code")) == (401, source.STALE_OWNER_SESSION_CODE)


@pytest.mark.asyncio
@pytest.mark.parametrize(("path", "handler"), ROUTES)
async def test_teammate_session_keeps_the_403(path, handler) -> None:
    status, body = await _status(path, handler, "U_TEAMMATE", mint=False)
    assert (status, body.get("code")) == (403, "owner_only")
