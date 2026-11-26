"""Device pairing in the local authorization store (RFC 8628): what a device may ask, how
the owner's answer reaches it, and what its grant may and may not do
(``dashboard/local_authorization.py``). The routes are in ``test_device_pairing_routes.py``."""

from __future__ import annotations

import json
from pathlib import Path
from unittest.mock import Mock

import pytest
from test_local_authorization import ASK, ISSUER, SUBJECT, Clock

from kiro_crew.dashboard import local_authorization as la

DEVICE = "kirocrew-ios"
SOURCE = "192.168.1.50"


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def audit(monkeypatch):
    audit = Mock(spec=["log_api_access"])
    monkeypatch.setattr(la, "sel", lambda: audit)
    return audit


@pytest.fixture
def store(tmp_path: Path, clock: Clock, audit) -> la.LocalAuthorization:
    return la.LocalAuthorization(tmp_path / "local-grants" / "state.json", b"k" * 32, clock)


def _ask(store: la.LocalAuthorization, source: str = SOURCE) -> dict:
    return store.device_authorize(DEVICE, "Alex's iPhone", source=source)


def _poll(store: la.LocalAuthorization, device_code: str, clock: Clock, wait: float = 5.0) -> dict:
    clock.now += wait
    return store.exchange_device_code(DEVICE, device_code, ISSUER, source=SOURCE)


def _paired(store: la.LocalAuthorization, clock: Clock) -> dict:
    asked = _ask(store)
    store.decide_device(asked["user_code"], True, caller=SUBJECT)
    return _poll(store, asked["device_code"], clock)


def _error(call) -> la.AuthError:
    with pytest.raises(la.AuthError) as raised:
        call()
    return raised.value


def test_a_device_asks_and_gets_the_rfc_8628_answer(store, clock):
    asked = _ask(store)
    assert asked["device_code"].startswith("dc_")
    assert len(asked["user_code"]) == 9 and asked["user_code"][4] == "-"
    assert asked["expires_in"] == la.DEVICE_REQUEST_TTL_SECS == 300
    assert asked["interval"] == la.DEVICE_POLL_INTERVAL_SECS == 5


def test_the_device_code_is_stored_as_a_digest_only(store, tmp_path):
    asked = _ask(store)
    record = (tmp_path / "local-grants" / "state.json").read_text()
    assert asked["device_code"] not in record
    assert la._digest(asked["device_code"]) in record


def test_polling_waits_then_pairs_after_the_owner_approves(store, clock):
    asked = _ask(store)
    assert _error(lambda: _poll(store, asked["device_code"], clock)).error == (
        "authorization_pending"
    )
    view = store.decide_device(asked["user_code"].lower(), True, caller=SUBJECT)
    assert view["status"] == "approved" and view["source"] == SOURCE
    assert view["client_name"] == "Alex's iPhone"
    tokens = _poll(store, asked["device_code"], clock)
    assert tokens["scope"] == "dashboard" and tokens["token_type"] == "Bearer"
    assert tokens["expires_in"] == la.ACCESS_TTL_SECS


def test_a_poll_inside_the_interval_is_slow_down_and_the_interval_grows(store, clock):
    asked = _ask(store)
    _error(lambda: _poll(store, asked["device_code"], clock))
    early = _error(lambda: _poll(store, asked["device_code"], clock, wait=1))
    assert (early.error, early.status, early.retry_after) == ("slow_down", 400, 10)
    # 5 seconds on is still too soon for the new 10-second interval.
    assert _error(lambda: _poll(store, asked["device_code"], clock, wait=5)).error == "slow_down"
    assert _error(lambda: _poll(store, asked["device_code"], clock, wait=15)).error == (
        "authorization_pending"
    )


def test_a_denied_request_answers_access_denied(store, clock):
    asked = _ask(store)
    store.decide_device(asked["user_code"], False, caller=SUBJECT)
    assert _error(lambda: _poll(store, asked["device_code"], clock)).error == "access_denied"


def test_an_expired_request_answers_expired_token_and_cannot_be_approved(store, clock):
    asked = _ask(store)
    clock.now += la.DEVICE_REQUEST_TTL_SECS
    assert _error(lambda: _poll(store, asked["device_code"], clock)).error == "expired_token"
    with pytest.raises(la.UnknownRequest):
        store.decide_device(asked["user_code"], True, caller=SUBJECT)


def test_an_unknown_expired_or_answered_code_is_the_same_refusal(store, clock):
    asked = _ask(store)
    store.decide_device(asked["user_code"], True, caller=SUBJECT)
    for code in (asked["user_code"], "BBBB-BBBB", "", "x" * 40):
        with pytest.raises(la.UnknownRequest):
            store.decide_device(code, True, caller=SUBJECT)


def test_the_device_code_belongs_to_the_client_that_asked(store, clock):
    asked = _ask(store)
    assert (
        _error(
            lambda: store.exchange_device_code("other", asked["device_code"], ISSUER, source=SOURCE)
        ).error
        == "invalid_grant"
    )
    assert (
        _error(
            lambda: store.exchange_device_code(DEVICE, "dc_unknown", ISSUER, source=SOURCE)
        ).error
        == "invalid_grant"
    )


def test_a_device_code_redeemed_twice_revokes_the_grant_it_gave(store, clock):
    asked = _ask(store)
    store.decide_device(asked["user_code"], True, caller=SUBJECT)
    tokens = _poll(store, asked["device_code"], clock)
    assert _error(lambda: _poll(store, asked["device_code"], clock)).error == "invalid_grant"
    assert store.verify_device(tokens["access_token"]) is None


def test_only_a_device_client_pairs_and_a_device_client_does_nothing_else(store):
    assert _error(lambda: store.device_authorize("notely-desktop", "", source=SOURCE)).error == (
        "unauthorized_client"
    )
    ask = {**ASK, "client_id": DEVICE}
    assert _error(lambda: store.authorize(ask)).error == "unauthorized_client"
    assert store.pending() == []


def test_the_dashboard_scope_cannot_be_asked_through_the_authorization_code_flow(store):
    kind, location = store.authorize({**ASK, "scope": "dashboard"})
    assert kind == "redirect" and "invalid_scope" in location
    assert "dashboard" not in la.SCOPES


def test_a_device_client_name_must_be_short_printable_text(store):
    for name in ("x" * 81, "bell\x07"):
        assert _error(lambda: store.device_authorize(DEVICE, name, source=SOURCE)).error == (
            "invalid_request"
        )


def test_pending_requests_are_capped_per_source_and_in_total(store, clock):
    for _ in range(la.DEVICE_MAX_PENDING_PER_SOURCE):
        _ask(store)
    capped = _error(lambda: _ask(store))
    assert (capped.error, capped.status) == ("temporarily_unavailable", 503)
    for index in range(la.DEVICE_MAX_PENDING - la.DEVICE_MAX_PENDING_PER_SOURCE):
        _ask(store, source=f"10.0.0.{index}")
    assert _error(lambda: _ask(store, source="10.9.9.9")).error == "temporarily_unavailable"
    clock.now += la.DEVICE_REQUEST_TTL_SECS
    _ask(store)


def test_a_device_request_does_not_touch_the_apps_request_list_or_its_cap(store):
    for _ in range(la.DEVICE_MAX_PENDING_PER_SOURCE):
        _ask(store)
    assert store.pending() == []
    kind, _ = store.authorize(ASK)
    assert kind == "created"


def test_user_codes_of_waiting_requests_never_repeat(store, monkeypatch):
    first = _ask(store)
    letters = iter(first["user_code"].replace("-", "") + "BCDFGHJK")
    monkeypatch.setattr(la.secrets, "choice", lambda _alphabet: next(letters))
    second = _ask(store, source="10.0.0.2")
    assert second["user_code"] == "BCDF-GHJK"


def test_a_device_grant_has_one_scope_and_is_listed_with_its_device_fields(store, clock):
    tokens = _paired(store, clock)
    [row] = store.grants()
    assert row["grant_id"] == tokens["grant_id"]
    assert (row["kind"], row["scopes"], row["client_name"]) == (
        "device",
        ["dashboard"],
        "Alex's iPhone",
    )
    assert row["last_ip"] == SOURCE and row["last_used_at"] == int(clock.now)
    assert row["expires_at"] == int(clock.now + la.DEVICE_REFRESH_IDLE_SECS)
    assert store.grant_class(tokens["grant_id"]) == "device"


def test_a_device_access_token_is_not_a_crew_api_credential(store, clock):
    tokens = _paired(store, clock)
    assert store.verify(tokens["access_token"]) is None
    credential = store.verify_device(tokens["access_token"])
    assert credential is not None and credential.grant_id == tokens["grant_id"]


def test_an_app_access_token_is_not_a_device_credential(store, clock):
    kind, view = store.authorize(ASK)
    store.decide(view["request_id"], True, caller=SUBJECT)
    clock.now += la.POLL_INTERVAL_SECS
    _, location = store.authorize({**ASK, "request_id": view["request_id"]})
    code = location.split("code=")[1].split("&")[0]
    from test_local_authorization import REDIRECT, VERIFIER

    app = store.exchange_code(ASK["client_id"], code, REDIRECT, VERIFIER, ISSUER)
    assert store.verify(app["access_token"]) is not None
    assert store.verify_device(app["access_token"]) is None


def test_a_device_grant_refreshes_for_90_days_idle_and_has_no_absolute_end(store, clock):
    tokens = _paired(store, clock)
    for _ in range(3):
        clock.now += 60 * 24 * 3600
        tokens = store.refresh(DEVICE, tokens["refresh_token"], "", ISSUER, remote=True)
    # 180 days from pairing, far past the 7-day cap of an app grant.
    assert store.verify_device(tokens["access_token"]) is not None
    clock.now += la.DEVICE_REFRESH_IDLE_SECS + 1
    assert (
        _error(
            lambda: store.refresh(DEVICE, tokens["refresh_token"], "", ISSUER, remote=True)
        ).error
        == "invalid_grant"
    )
    assert store.grants() == []


def test_the_far_expiry_survives_the_records_pruning(store, clock):
    tokens = _paired(store, clock)
    clock.now += 5 * 365 * 24 * 3600
    record = json.loads(store._path.read_text())
    assert tokens["grant_id"] in record["grants"]


def test_a_non_local_caller_refreshes_a_device_grant_and_nothing_else(store, clock):
    device = _paired(store, clock)
    store.refresh(DEVICE, device["refresh_token"], "", ISSUER, remote=True)
    kind, view = store.authorize(ASK)
    store.decide(view["request_id"], True, caller=SUBJECT)
    clock.now += la.POLL_INTERVAL_SECS
    _, location = store.authorize({**ASK, "request_id": view["request_id"]})
    from test_local_authorization import REDIRECT, VERIFIER

    app = store.exchange_code(
        ASK["client_id"], location.split("code=")[1].split("&")[0], REDIRECT, VERIFIER, ISSUER
    )
    assert (
        _error(
            lambda: store.refresh(ASK["client_id"], app["refresh_token"], "", ISSUER, remote=True)
        ).error
        == "invalid_grant"
    )
    # Still good for the machine's own caller: the refusal changed nothing.
    store.refresh(ASK["client_id"], app["refresh_token"], "", ISSUER)


def test_a_refresh_stamps_the_last_use(store, clock):
    tokens = _paired(store, clock)
    clock.now += 100
    store.refresh(DEVICE, tokens["refresh_token"], "", ISSUER, remote=True, source="")
    [row] = store.grants()
    assert row["last_used_at"] == int(clock.now) and row["last_ip"] == ""


def test_the_token_just_used_works_again_inside_the_grace_and_gives_the_same_next_token(
    store, clock
):
    first = _paired(store, clock)
    second = store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)
    clock.now += la.DEVICE_ROTATION_GRACE_SECS
    retried = store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)
    assert retried["refresh_token"] == second["refresh_token"]
    assert store.verify_device(retried["access_token"]) is not None
    # The answer to the retry rotates on from there: one counter, no fork.
    third = store.refresh(DEVICE, second["refresh_token"], "", ISSUER, remote=True)
    assert third["refresh_token"] != second["refresh_token"]


def test_a_token_replayed_after_the_grace_revokes_the_grant(store, clock):
    first = _paired(store, clock)
    second = store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)
    clock.now += la.DEVICE_ROTATION_GRACE_SECS + 1
    assert (
        _error(lambda: store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)).error
        == "invalid_grant"
    )
    assert store.verify_device(second["access_token"]) is None
    assert store.grants() == []


def test_a_token_two_rotations_old_revokes_even_inside_the_grace(store, clock):
    first = _paired(store, clock)
    second = store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)
    store.refresh(DEVICE, second["refresh_token"], "", ISSUER, remote=True)
    assert (
        _error(lambda: store.refresh(DEVICE, first["refresh_token"], "", ISSUER, remote=True)).error
        == "invalid_grant"
    )
    assert store.grants() == []


def test_an_app_grant_keeps_no_grace(store, clock):
    kind, view = store.authorize(ASK)
    store.decide(view["request_id"], True, caller=SUBJECT)
    clock.now += la.POLL_INTERVAL_SECS
    _, location = store.authorize({**ASK, "request_id": view["request_id"]})
    from test_local_authorization import REDIRECT, VERIFIER

    app = store.exchange_code(
        ASK["client_id"], location.split("code=")[1].split("&")[0], REDIRECT, VERIFIER, ISSUER
    )
    store.refresh(ASK["client_id"], app["refresh_token"], "", ISSUER)
    assert (
        _error(lambda: store.refresh(ASK["client_id"], app["refresh_token"], "", ISSUER)).error
        == "invalid_grant"
    )


def test_a_revoked_device_grant_keeps_its_class_and_expires_after_90_days(store, clock):
    tokens = _paired(store, clock)
    assert store.revoke_grant(tokens["grant_id"], caller=SUBJECT)
    assert store.grant_class(tokens["grant_id"]) == "device"
    assert store.verify_device(tokens["access_token"]) is None
    record = json.loads(store._path.read_text())["grants"][tokens["grant_id"]]
    assert record == {
        "class": "device",
        "status": "revoked",
        "expires_at": clock.now + la.DEVICE_REVOKED_KEEP_SECS,
    }
    clock.now += la.DEVICE_REVOKED_KEEP_SECS + 1
    _ask(store)
    assert tokens["grant_id"] not in json.loads(store._path.read_text())["grants"]


def test_the_app_giving_up_a_device_grant_names_it_and_a_remote_caller_cannot_end_an_app(
    store, clock
):
    tokens = _paired(store, clock)
    ended, grant_id = store.revoke_presented(tokens["refresh_token"], remote=True)
    assert (ended, grant_id) == (True, tokens["grant_id"])
    # Again: nothing to end, but the grant is still named so the sessions are ended too.
    assert store.revoke_presented(tokens["refresh_token"], remote=True) == (
        False,
        tokens["grant_id"],
    )
    assert _error(lambda: store.revoke_presented("lr_nothing", remote=True)).status == 404
    assert store.revoke_presented("lr_nothing", remote=False) == (False, "")


def test_a_device_access_token_does_not_survive_its_grants_revocation(store, clock):
    tokens = _paired(store, clock)
    assert store.verify_device(tokens["access_token"]) is not None
    store.revoke_grant(tokens["grant_id"], caller=SUBJECT)
    assert store.verify_device(tokens["access_token"]) is None


def test_a_record_written_before_devices_still_loads(store, tmp_path):
    path = tmp_path / "local-grants" / "state.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"requests": {}, "grants": {}}) + "\n")
    assert _ask(store)["user_code"]


def test_the_owner_decision_is_audited_with_the_request_id_and_never_the_device_name(store, audit):
    asked = _ask(store)
    store.decide_device(asked["user_code"], True, caller=SUBJECT)
    kwargs = audit.log_api_access.call_args.kwargs
    assert kwargs["operation"] == "local_auth.device_decide" and kwargs["critical"] is True
    assert kwargs["caller"] == SUBJECT
    assert "iPhone" not in json.dumps(kwargs)
