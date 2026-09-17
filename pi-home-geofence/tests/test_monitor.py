import json
from datetime import datetime, timezone

import pytest

from home_geofence.config import ConfigError, load_config
from home_geofence.geo import Sample, Transition, Zone
from home_geofence.monitor import Monitor, StateStore, build_tracker, in_quiet_hours
from home_geofence.notifiers import Notifier
from home_geofence.providers import FileProvider, LocationProvider, ProviderError

HOME = (-33.4489, -70.6693)


class FakeProvider(LocationProvider):
    def __init__(self, samples):
        self.samples = list(samples)

    def get_sample(self):
        item = self.samples.pop(0)
        if isinstance(item, Exception):
            raise item
        return item


class MemoryNotifier(Notifier):
    name = "memory"

    def __init__(self):
        self.sent = []

    def send(self, title, body):
        self.sent.append((title, body))


def sample(dist_m, accuracy=20.0):
    return Sample(latitude=HOME[0] + dist_m / 111_320.0, longitude=HOME[1],
                  timestamp=datetime.now(timezone.utc), accuracy_m=accuracy, address="Calle Falsa 123")


def write_config(tmp_path, **overrides):
    cfg = {
        "child_name": "Peque",
        "home": {"latitude": HOME[0], "longitude": HOME[1], "radius_m": 100, "confirm_samples": 1},
        "file_provider": {"path": str(tmp_path / "pos.json")},
        "notify": {"console": False},
        "state_file": str(tmp_path / "state.json"),
    }
    cfg.update(overrides)
    import yaml
    p = tmp_path / "config.yaml"
    p.write_text(yaml.safe_dump(cfg), encoding="utf-8")
    return p


def test_arrival_sends_one_notification(tmp_path):
    cfg = load_config(write_config(tmp_path))
    notifier = MemoryNotifier()
    m = Monitor(cfg, FakeProvider([sample(2000), sample(10), sample(10)]), [notifier], build_tracker(cfg))
    m.tick(); m.tick(); m.tick()
    assert len(notifier.sent) == 1
    title, body = notifier.sent[0]
    assert "Peque" in title and "llegó" in title
    assert "Calle Falsa 123" in body


def test_leave_can_be_muted(tmp_path):
    cfg = load_config(write_config(tmp_path, notify={"console": False, "on_leave": False}))
    notifier = MemoryNotifier()
    m = Monitor(cfg, FakeProvider([sample(10), sample(2000)]), [notifier], build_tracker(cfg))
    ev1 = m.tick(); ev2 = m.tick()
    assert ev2.transition == Transition.LEFT
    assert notifier.sent == []


def test_state_persists_across_restart(tmp_path):
    cfg = load_config(write_config(tmp_path))
    n1 = MemoryNotifier()
    m1 = Monitor(cfg, FakeProvider([sample(10)]), [n1], build_tracker(cfg))
    m1.tick()
    assert json.loads((tmp_path / "state.json").read_text())["zone"] == "inside"

    # Nuevo proceso: al arrancar ya "sabe" que estaba en casa → una salida sí avisa
    n2 = MemoryNotifier()
    m2 = Monitor(cfg, FakeProvider([sample(2000)]), [n2], build_tracker(cfg))
    assert m2.tracker.zone == Zone.INSIDE
    m2.tick()
    assert len(n2.sent) == 1 and "salió" in n2.sent[0][0]


def test_provider_errors_are_logged_not_raised(tmp_path):
    cfg = load_config(write_config(tmp_path))
    m = Monitor(cfg, FakeProvider([ProviderError("boom"), sample(10)]), [MemoryNotifier()], build_tracker(cfg))
    assert m.tick() is None
    assert m._consecutive_errors == 1
    assert m.tick() is not None
    assert m._consecutive_errors == 0


def test_failing_notifier_does_not_break_others(tmp_path):
    class Broken(Notifier):
        name = "broken"

        def send(self, title, body):
            raise RuntimeError("sin red")

    cfg = load_config(write_config(tmp_path))
    good = MemoryNotifier()
    m = Monitor(cfg, FakeProvider([sample(2000), sample(10)]), [Broken(), good], build_tracker(cfg))
    m.tick(); m.tick()
    assert len(good.sent) == 1


def test_file_provider_roundtrip(tmp_path):
    p = tmp_path / "pos.json"
    p.write_text(json.dumps({"latitude": 1.0, "longitude": 2.0, "accuracy": 30,
                             "timestamp": "2026-09-17T10:00:00+00:00", "battery_level": 55}))
    s = FileProvider(str(p)).get_sample()
    assert (s.latitude, s.longitude, s.accuracy_m, s.battery_level) == (1.0, 2.0, 30.0, 55)
    assert s.timestamp.tzinfo is not None
    assert FileProvider(str(tmp_path / "missing.json")).get_sample() is None


@pytest.mark.parametrize("quiet,hour,expected", [
    (None, 3, False),
    ((23, 7), 23, True), ((23, 7), 3, True), ((23, 7), 7, False), ((23, 7), 12, False),
    ((9, 17), 12, True), ((9, 17), 8, False),
    ((5, 5), 5, False),
])
def test_quiet_hours(quiet, hour, expected):
    assert in_quiet_hours(quiet, datetime(2026, 1, 1, hour, 30)) is expected


def test_config_requires_home_and_provider(tmp_path):
    p = tmp_path / "c.yaml"
    p.write_text("home: {latitude: 1}\n")
    with pytest.raises(ConfigError):
        load_config(p)
    p.write_text("home: {latitude: 1, longitude: 2}\n")
    with pytest.raises(ConfigError):
        load_config(p)


def test_config_expands_env_vars(tmp_path, monkeypatch):
    monkeypatch.setenv("TG_TOKEN", "123:abc")
    p = write_config(tmp_path, notify={"console": False, "telegram": {"bot_token": "${TG_TOKEN}", "chat_id": 42}})
    cfg = load_config(p)
    assert cfg.telegram.bot_token == "123:abc"
    assert cfg.telegram.chat_id == "42"


def test_state_store_handles_corrupt_file(tmp_path):
    p = tmp_path / "state.json"
    p.write_text("{not json")
    assert StateStore(str(p)).load() == Zone.UNKNOWN
