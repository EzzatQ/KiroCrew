"""``kirocrew token`` on a gateway bound to a LAN address mints over the owner-only socket.

A gateway bound to a specific interface (``KIROCREW_BIND``) publishes no loopback listener
sidecar, so a secret paired with 127.0.0.1 fails closed. The mint rides the unix socket,
so it needs no loopback pairing; without the socket the fail-closed pairing stays.
"""

import argparse
import json
import socket
import tempfile
import threading

import pytest

from kiro_crew import cli_server
from kiro_crew.cli_server import _token
from kiro_crew.instances import run_marker

PORT = 7777


def _serve_mint(path: str, seen: list, reply: dict | None = None) -> threading.Thread:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    def run() -> None:
        conn, _ = srv.accept()
        with conn:
            seen.append(conn.recv(65536).decode("latin-1"))
            body = json.dumps(reply or {"token": "minted-tok"}).encode()
            conn.sendall(
                b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                + str(len(body)).encode()
                + b"\r\n\r\n"
                + body
            )
        srv.close()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


@pytest.fixture
def lan_bound(monkeypatch):
    """Listener entries exist, none for loopback: the real fail-closed shape."""
    monkeypatch.setattr(run_marker, "read_listener_secret", lambda _p, _h: "")
    monkeypatch.setattr(run_marker, "has_listener_entries", lambda _p: True)
    monkeypatch.setattr(run_marker, "read_secret", lambda _p: "port-secret")
    monkeypatch.setattr(cli_server, "_probe_dashboard_health", lambda _p: None)
    monkeypatch.setattr(cli_server, "_emit_session_urls", lambda _p, tok: print(f"URL?token={tok}"))
    monkeypatch.setattr(cli_server, "run_preflight_checks", lambda: None)


def test_mints_over_the_socket_when_bound_to_a_lan_address(
    lan_bound, monkeypatch, tmp_path, capsys
):
    short = tempfile.mkdtemp(prefix="kc")  # AF_UNIX paths are short; tmp_path is not
    sock_path = short + "/d.sock"
    seen: list[str] = []
    thread = _serve_mint(sock_path, seen)
    monkeypatch.setattr(cli_server, "dashboard_socket_path", lambda _p: sock_path)
    monkeypatch.setattr(
        cli_server, "check_peer_is_self", lambda _s: cli_server.PeerCredResult.MATCH
    )
    monkeypatch.setattr(cli_server, "_connected_unix_peer_is_recorded_gateway", lambda _s, _p: True)
    monkeypatch.setattr(cli_server, "_audit_peer_allowed", lambda *_a: None)

    _token(argparse.Namespace(ttl="1h", port=PORT))
    thread.join(5)

    assert "URL?token=minted-tok" in capsys.readouterr().out
    assert "port-secret" in seen[0]


def test_stays_fail_closed_without_the_socket(lan_bound, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli_server, "dashboard_socket_path", lambda _p: str(tmp_path / "none"))

    with pytest.raises(SystemExit) as exc:
        _token(argparse.Namespace(ttl="1h", port=PORT))

    assert exc.value.code == 1
    assert "Gateway not running" in capsys.readouterr().err


def test_logout_revokes_over_the_socket_when_bound_to_a_lan_address(lan_bound, monkeypatch, capsys):
    short = tempfile.mkdtemp(prefix="kc")
    sock_path = short + "/d.sock"
    seen: list[str] = []
    thread = _serve_mint(sock_path, seen, {"ok": True})
    monkeypatch.setattr(cli_server, "dashboard_socket_path", lambda _p: sock_path)
    monkeypatch.setattr(
        cli_server, "check_peer_is_self", lambda _s: cli_server.PeerCredResult.MATCH
    )
    monkeypatch.setattr(cli_server, "_connected_unix_peer_is_recorded_gateway", lambda _s, _p: True)
    monkeypatch.setattr(cli_server, "_audit_peer_allowed", lambda *_a: None)

    cli_server._logout(PORT)
    thread.join(5)

    assert "/api/logout" in seen[0]
    assert "port-secret" in seen[0]


def test_logout_stays_fail_closed_without_the_socket(lan_bound, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(cli_server, "dashboard_socket_path", lambda _p: str(tmp_path / "none"))

    with pytest.raises(SystemExit) as exc:
        cli_server._logout(PORT)

    assert exc.value.code == 1
    assert "Gateway not running" in capsys.readouterr().err
