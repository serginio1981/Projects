import pytest

from home_geofence.notifiers import HomeAssistantNotifier, TelegramNotifier, broadcast


class FakeResponse:
    def __init__(self, status=200, payload=None):
        self.status_code = status
        self._payload = payload or {"ok": True}

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._payload


def test_home_assistant_posts_context_as_json(monkeypatch):
    import requests

    sent = {}

    def fake_post(url, json=None, timeout=None):
        sent.update(url=url, json=json, timeout=timeout)
        return FakeResponse()

    monkeypatch.setattr(requests, "post", fake_post)
    n = HomeAssistantNotifier("http://homeassistant.local:8123/api/webhook/abc")
    n.send("Título", "Cuerpo", {"latitude": -33.4, "longitude": -70.6, "event": "entered"})
    assert sent["url"].endswith("/api/webhook/abc")
    assert sent["json"] == {"title": "Título", "message": "Cuerpo", "latitude": -33.4, "longitude": -70.6,
                            "event": "entered"}


def test_home_assistant_http_error_propagates(monkeypatch):
    import requests

    monkeypatch.setattr(requests, "post", lambda *a, **k: FakeResponse(status=404))
    with pytest.raises(RuntimeError):
        HomeAssistantNotifier("http://ha/api/webhook/x").send("t", "b")


def test_home_assistant_requires_url():
    with pytest.raises(ValueError):
        HomeAssistantNotifier("")


def test_telegram_rejects_not_ok_payload(monkeypatch):
    import requests

    monkeypatch.setattr(requests, "post", lambda *a, **k: FakeResponse(payload={"ok": False, "description": "bad"}))
    with pytest.raises(RuntimeError, match="rechazó"):
        TelegramNotifier("123:abc", "42").send("t", "b")


def test_broadcast_passes_context_to_every_channel():
    seen = []

    class N:
        name = "n"

        def send(self, title, body, context=None):
            seen.append(context)

    assert broadcast([N(), N()], "t", "b", {"k": 1}) == 0
    assert seen == [{"k": 1}, {"k": 1}]
