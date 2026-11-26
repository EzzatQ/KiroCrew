"""The owner's side of local authorization: list the waiting grant requests, read one,
answer one, list the grants, revoke one and answer a device pairing request.

Handlers for ``GET /v1/crew/owner/grant-requests``,
``GET /v1/crew/owner/grant-requests/{request_id}``,
``POST /v1/crew/owner/grant-requests/{request_id}/decision``,
``POST /v1/crew/owner/device-approvals``,
``GET /v1/crew/owner/grants`` and ``DELETE /v1/crew/owner/grants/{grant_id}``. They are served only through
:func:`kiro_crew.dashboard.crew_api_owner.owner_route`, which supplies the Crew API
error shape and the ordinary owner gate. Every handler additionally requires the host
owner: a Shared Crew teammate may use the dashboard but cannot grant or revoke a local
credential, or read the machine's application requests.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from aiohttp import web

from kiro_crew.config.loader import KiroCrewConfig
from kiro_crew.config.resolution import DEGRADED_WHOLE_CONFIG
from kiro_crew.dashboard import device_pair_claim as pair
from kiro_crew.dashboard import local_authorization as la
from kiro_crew.dashboard.device_rate_limit import SlidingWindowLimiter
from kiro_crew.dashboard.handlers.source_providers import is_host_owner_dashboard_request
from kiro_crew.dashboard.token_auth_tokens import revoke_family_id
from kiro_crew.members import is_dispatchable_member_name

logger = logging.getLogger(__name__)


def _grant_request(view: dict[str, Any]) -> dict[str, Any]:
    """A stored request in the contract's ``GrantRequest`` shape."""
    return {
        "id": view["request_id"],
        "object": "grant_request",
        "namespace": view["namespace"],
        "status": view["status"],
        "client_id": view["client_id"],
        "client_name": view["client_name"],
        # A program on this machine reported the name and id; nothing verified them.
        "verified": False,
        "redirect_uri": view["redirect_uri"],
        "user_code": view["user_code"],
        "requested_scopes": view["requested_scopes"],
        "requested_bots": view["requested_bots"],
        "created_at": view["created_at"],
        "expires_at": view["expires_at"],
        "decided_at": view["decided_at"],
        "decided_by": view["decided_by"],
        "grant_id": view["grant_id"],
        # Present only on an approved request: what the owner gave, which may be fewer.
        **({"granted_scopes": view["granted_scopes"]} if "granted_scopes" in view else {}),
        # Present only on an approved request: the Bots the owner gave, which may be none.
        **({"granted_bots": view["granted_bots"]} if "granted_bots" in view else {}),
    }


async def _existing_bots() -> set[str]:
    """Bot ids from a confirmed config read, without a fallback roster."""
    config = await asyncio.to_thread(KiroCrewConfig.load)
    if config.degraded_sections & {DEGRADED_WHOLE_CONFIG, "agents"}:
        raise ValueError("the Bot roster is degraded")
    return {name for name in config.agents if is_dispatchable_member_name(name)}


def _error(status: int, code: str, message: str) -> web.Response:
    return web.json_response({"error": message, "code": code}, status=status)


# shortcut: a decision must fit in 4 KiB, so the owner may need a shorter Bot list;
# raise this limit when decisions need to carry every requested Bot at once.
_BODY_MAX = 4 * 1024

_UNAVAILABLE = (503, "instance_unavailable", "local authorization is unavailable")

#: The contract's ``GrantStatus`` values and its ``Limit`` parameter.
_GRANT_STATUSES = ("active", "throttled", "paused", "revoked")
_LIMIT_DEFAULT = 20
_LIMIT_MAX = 100


async def _host_owner_refusal(request: web.Request, operation: str) -> web.Response | None:
    if is_host_owner_dashboard_request(request):
        return None
    caller = str(request.get("user") or "unknown")

    def audit() -> None:
        from kiro_crew.sel import sel

        sel().log_api_access(
            caller=caller,
            operation=operation,
            outcome="denied",
            source="dashboard",
            resources="non_owner_block",
        )

    try:
        await asyncio.to_thread(audit)
    except Exception:
        logger.warning("Local consent host-owner denial audit failed")
    return _error(403, "owner_only", "host owner authorization required")


async def list_grant_requests(request: web.Request) -> web.Response:
    """The requests waiting for the host owner's consent, oldest first."""
    if (denied := await _host_owner_refusal(request, "crew_api.grant_requests.list")) is not None:
        return denied
    try:
        waiting = await asyncio.to_thread(lambda: la.gateway_local_authorization().pending())
    except (OSError, ValueError, KeyError, TypeError):
        return _error(*_UNAVAILABLE)
    data = sorted((_grant_request(v) for v in waiting), key=lambda r: r["created_at"])
    return web.json_response(
        {
            "object": "list",
            "data": data,
            "first_id": data[0]["id"] if data else None,
            "last_id": data[-1]["id"] if data else None,
            "has_more": False,
        }
    )


async def get_grant_request(request: web.Request) -> web.Response:
    """One request, answered or not, for as long as the record keeps it."""
    if (denied := await _host_owner_refusal(request, "crew_api.grant_requests.get")) is not None:
        return denied
    request_id = request.match_info["request_id"]
    try:
        view = await asyncio.to_thread(lambda: la.gateway_local_authorization().request(request_id))
    except la.UnknownRequest:
        return _error(404, "not_found", "no such grant request, or it has expired")
    except (OSError, ValueError, KeyError, TypeError):
        return _error(*_UNAVAILABLE)
    return web.json_response(_grant_request(view))


def _grant(view: dict[str, Any]) -> dict[str, Any]:
    """A stored grant in the contract's ``Grant`` shape, with what this store keeps."""
    device = view.get("kind") == la.DEVICE_CLASS
    return {
        "id": view["grant_id"],
        "object": "grant",
        # Made through local authorization, by this gateway. A device grant says so, and
        # adds when it last refreshed and from where (``""`` behind a tunnel).
        "kind": "device" if device else "local",
        **({"last_used_at": view["last_used_at"], "last_ip": view["last_ip"]} if device else {}),
        "namespace": view["namespace"],
        "client_id": view["client_id"],
        # As the app reported them; nothing verified the name or the id.
        "app": {"name": view["client_name"], "icon_url": None},
        "scopes": view["scopes"],
        "bots": view["bots"],
        "status": view["status"],
        "created_at": view["created_at"],
        "expires_at": view["expires_at"],
    }


async def list_grants(request: web.Request) -> web.Response:
    """The grants that work now, oldest first. A revoked grant is not listed."""
    if (denied := await _host_owner_refusal(request, "crew_api.grants.list")) is not None:
        return denied
    query = request.query
    wanted = query.get("status", "active")
    raw_limit = query.get("limit", str(_LIMIT_DEFAULT))
    if wanted not in _GRANT_STATUSES:
        return _error(400, "invalid_request", "status must be active, throttled, paused or revoked")
    if len(raw_limit) > len(str(_LIMIT_MAX)) or not (
        raw_limit.isascii() and raw_limit.isdigit() and 1 <= int(raw_limit) <= _LIMIT_MAX
    ):
        return _error(400, "invalid_request", f"limit must be 1 to {_LIMIT_MAX}")
    try:
        views = await asyncio.to_thread(lambda: la.gateway_local_authorization().grants())
    except (OSError, ValueError, KeyError, TypeError):
        return _error(*_UNAVAILABLE)
    # A local grant is active or gone: the other three statuses match nothing.
    rows = [_grant(v) for v in views] if wanted == "active" else []
    if "after" in query:
        ids = [r["id"] for r in rows]
        if query["after"] not in ids:
            return _error(400, "invalid_request", "after names no grant in this list")
        rows = rows[ids.index(query["after"]) + 1 :]
    limit = int(raw_limit)
    data = rows[:limit]
    return web.json_response(
        {
            "object": "list",
            "data": data,
            "first_id": data[0]["id"] if data else None,
            "last_id": data[-1]["id"] if data else None,
            "has_more": len(rows) > limit,
        }
    )


async def revoke_grant(request: web.Request) -> web.Response:
    """Revoke one grant and every token under it. A second call answers the same."""
    if (denied := await _host_owner_refusal(request, "crew_api.grants.revoke")) is not None:
        return denied
    grant_id = request.match_info["grant_id"]
    # Token auth set this subject; _host_owner_refusal proved it is the host owner's.
    subject = str(request["user"])
    try:
        revoked = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().revoke_grant(grant_id, caller=subject)
        )
    except Exception:
        # The record cannot be read or written, or the audit row failed.
        return _error(*_UNAVAILABLE)
    if not revoked:
        return _error(404, "not_found", "no such grant, or it has expired")
    try:
        device = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().grant_class(grant_id) == la.DEVICE_CLASS
        )
        if device:
            # The cookie chains a device opened end with its grant, at once. Repeating the
            # call finishes a revoke whose first attempt could not store this.
            await asyncio.to_thread(revoke_family_id, grant_id)
    except Exception:
        return _error(
            503,
            "cookie_revocation_failed",
            "the grant is revoked but its dashboard sessions could not be ended; retry",
        )
    return web.json_response({"id": grant_id, "object": "grant", "deleted": True})


#: Answers to the owner's device-approval call per minute. The code is 8 characters of a
#: 28-letter alphabet and lives 5 minutes; this keeps a stolen owner cookie from guessing it.
_APPROVAL_LIMIT = SlidingWindowLimiter(10)


def _pair_refusal(code: str) -> web.Response:
    return _error(403, code, "this sign-in link can pair only the phone that opened it, once")


def _audit_pair(subject: str, outcome: str, reason: str, view: dict[str, Any]) -> None:
    """One row for each answer a one-scan pair session gives or is refused: who, which
    device and from where. Never the code. A failed write does not change the answer."""
    try:
        from kiro_crew.sel import sel

        sel().log_api_access(
            caller=subject,
            operation="local_auth.device_pair_once",
            outcome=outcome,
            source="local-authorization",
            resources=f"client={view.get('client_id', '')}; ip={view.get('source', '')}"
            + (f"; reason={reason}" if reason else ""),
            critical=outcome == "approved",
        )
    except Exception:
        logger.warning("Device pair-claim audit failed")


#: Lists per minute. The Devices page polls this while it is open, so it has a budget
#: of its own and never uses up the owner's answers.
_LIST_LIMIT = SlidingWindowLimiter(30)


def _device_request(view: dict[str, Any]) -> dict[str, Any]:
    return {
        "object": "device_request",
        "client_id": view["client_id"],
        # Reported by the device; nothing verified it.
        "device_name": view["client_name"],
        "verified": False,
        # The caller's address; empty behind a tunnel, which hides it.
        "source_ip": view["source"],
        "via_tunnel": not view["source"],
        "created_at": view["created_at"],
        "expires_at": view["expires_at"],
        "age": view["age"],
        "expires_in": view["expires_in"],
    }


async def _list_devices(request: web.Request) -> web.Response:
    """The pairing requests waiting for the owner, oldest first, each with the code the
    device shows, so the owner can compare it and answer in one press."""
    subject = str(request["user"])
    if _LIST_LIMIT.limited(subject):
        return _error(429, "rate_limited", "too many attempts; wait a minute")
    try:
        waiting = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().pending_device_requests(caller=subject)
        )
    except Exception:
        return _error(*_UNAVAILABLE)
    if family := pair.claim_family(request):
        # A one-scan pair session sees only what its own claim may answer.
        waiting = [
            v
            for v in waiting
            if not pair.claims.refusal(family, created_at=v["created_at"], source=v["source"])
        ]
    data = [{**_device_request(v), "user_code": v["user_code"]} for v in waiting]
    return web.json_response(
        {
            "object": "list",
            "data": data,
            "first_id": data[0]["user_code"] if data else None,
            "last_id": data[-1]["user_code"] if data else None,
            "has_more": False,
        }
    )


async def lookup_device(request: web.Request) -> web.Response:
    """Who asks, for the pairing request that shows ``?user_code=``. Changes nothing, so the
    owner can read the device name, address and age before pressing Approve. Same owner
    gate, same rate limit and same uniform 404 as :func:`approve_device`."""
    if (
        denied := await _host_owner_refusal(request, "crew_api.device_approvals.lookup")
    ) is not None:
        return denied
    if "user_code" not in request.query:
        return await _list_devices(request)
    code = request.query.get("user_code", "")
    if not 0 < len(code) <= 32:
        return _error(400, "invalid_request", "user_code is required")
    subject = str(request["user"])
    if _APPROVAL_LIMIT.limited(subject):
        return _error(429, "rate_limited", "too many attempts; wait a minute")
    try:
        view = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().device_request_for_owner(code, caller=subject)
        )
    except la.UnknownRequest:
        return _error(404, "not_found", "no such pairing request, or it has expired")
    except Exception:
        return _error(*_UNAVAILABLE)
    if family := pair.claim_family(request):
        # A one-scan pair session sees only the request its own claim may answer.
        if refusal := pair.claims.refusal(
            family, created_at=view["created_at"], source=view["source"]
        ):
            return _pair_refusal(refusal)
    return web.json_response(_device_request(view))


async def approve_device(request: web.Request) -> web.Response:
    """Answer the pairing request that shows ``user_code``: approve it, or deny it with
    ``"approve": false``. The owner reads the code off the device, so a code that is
    unknown, expired or already answered is the same 404."""
    if (
        denied := await _host_owner_refusal(request, "crew_api.device_approvals.decide")
    ) is not None:
        return denied
    if request.content_length is None or request.content_length > _BODY_MAX:
        return _error(400, "invalid_request", "the body is missing its length or too large")
    try:
        body = await request.json()
    except ValueError:
        body = None
    approve = body.get("approve", True) if isinstance(body, dict) else None
    code = body.get("user_code") if isinstance(body, dict) else None
    if not (isinstance(code, str) and 0 < len(code) <= 32 and isinstance(approve, bool)):
        return _error(400, "invalid_request", "user_code is required and approve must be a boolean")
    subject = str(request["user"])
    if _APPROVAL_LIMIT.limited(subject):
        return _error(429, "rate_limited", "too many attempts; wait a minute")
    family = pair.claim_family(request)
    spent = False
    if family:
        # A one-scan pair session answers ONE request: the one made soon after its link
        # redeemed, from the address that redeemed it. Everything else is refused here,
        # whether or not the claim is still unspent.
        try:
            seen = await asyncio.to_thread(
                lambda: la.gateway_local_authorization().device_request_for_owner(
                    code, caller=subject
                )
            )
        except la.UnknownRequest:
            return _error(404, "not_found", "no such pairing request, or it has expired")
        except Exception:
            return _error(*_UNAVAILABLE)
        if refusal := pair.claims.refusal(
            family, created_at=seen["created_at"], source=seen["source"]
        ):
            await asyncio.to_thread(_audit_pair, subject, "refused", refusal, seen)
            return _pair_refusal(refusal)
        if approve:
            if not pair.claims.spend(family):
                return _pair_refusal(pair.SPENT)
            spent = True
    try:
        view = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().decide_device(code, approve, caller=subject)
        )
    except la.UnknownRequest:
        if spent:
            pair.claims.unspend(family)
        return _error(404, "not_found", "no such pairing request, or it has expired")
    except Exception:
        if spent:
            pair.claims.unspend(family)
        return _error(*_UNAVAILABLE)
    if spent:
        await asyncio.to_thread(_audit_pair, subject, "approved", "", view)
    return web.json_response(
        {
            "object": "device_approval",
            "status": view["status"],
            "client_id": view["client_id"],
            # Reported by the device; nothing verified it.
            "device_name": view["client_name"],
            "verified": False,
            "source_ip": view["source"],
            "created_at": view["created_at"],
            "expires_at": view["expires_at"],
        }
    )


async def decide_grant_request(request: web.Request) -> web.Response:
    """Approve or deny one request. An approval may narrow the scopes, never widen them."""
    if (denied := await _host_owner_refusal(request, "crew_api.grant_requests.decide")) is not None:
        return denied
    if request.content_length is None or request.content_length > _BODY_MAX:
        return _error(400, "invalid_request", "the body is missing its length or too large")
    try:
        body = await request.json()
    except ValueError:
        body = None
    if not isinstance(body, dict) or body.get("decision") not in ("approve", "deny"):
        return _error(400, "invalid_request", "decision must be approve or deny")
    scopes = body.get("scopes")
    if scopes is not None and not (
        isinstance(scopes, list) and all(isinstance(s, str) for s in scopes)
    ):
        return _error(400, "invalid_request", "scopes must be a list of strings")
    approve = body["decision"] == "approve"
    request_id = request.match_info["request_id"]
    try:
        pending = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().request_for_decision(request_id)
        )
    except la.UnknownRequest:
        return _error(404, "not_found", "no such grant request, or it has expired")
    except la.RequestAlreadyAnswered:
        return _error(409, "grant_request_already_resolved", "this request was already answered")
    except Exception:
        return _error(*_UNAVAILABLE)
    # Left out, an approval gives no Bot: a Bot is never given by default.
    bots = body.get("bots", []) if approve else None
    if approve:
        if not (isinstance(bots, list) and all(isinstance(b, str) for b in bots)):
            return _error(400, "invalid_request", "bots must be a list of strings")
        try:
            la.validate_bots(bots)
        except la.AuthError as exc:
            return _error(400, exc.error, exc.description)
        if not set(bots) <= set(pending["requested_bots"]):
            return _error(400, "invalid_request", "bots must be a subset of the requested bots")
    if bots:
        # A Bot is given only while this Kiro Crew has it. A roster that cannot be
        # read gives none.
        try:
            existing = await _existing_bots()
        except Exception:
            return _error(*_UNAVAILABLE)
        if not set(bots) <= existing:
            return _error(400, "invalid_request", "bots names a Bot this Kiro Crew does not have")
    # Token auth set this subject; _host_owner_refusal proved it is the host owner's.
    subject = str(request["user"])
    try:
        # The store is built in the worker thread too: its path lookup can touch disk.
        view = await asyncio.to_thread(
            lambda: la.gateway_local_authorization().decide(
                request_id, approve, scopes if approve else None, bots=bots, caller=subject
            )
        )
    except la.UnknownRequest:
        return _error(404, "not_found", "no such grant request, or it has expired")
    except la.RequestAlreadyAnswered:
        return _error(409, "grant_request_already_resolved", "this request was already answered")
    except la.ScopesNotRequested:
        return _error(400, "invalid_scope", "scopes must be a subset of the requested scopes")
    except la.BotsNotRequested:
        return _error(400, "invalid_request", "bots must be a subset of the requested bots")
    except Exception:
        # The record cannot be read or written, or the audit row failed.
        return _error(*_UNAVAILABLE)
    return web.json_response(_grant_request(view))
