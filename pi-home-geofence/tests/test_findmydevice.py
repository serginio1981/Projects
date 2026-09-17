"""Pruebas del proveedor Find My Device.

Lo que se puede probar sin Google: validación de secrets.json, elección del
mejor informe, búsqueda del dispositivo por nombre/id, la limitación de
frecuencia y el redireccionamiento de secrets.json dentro de la herramienta
vendida. La consulta real a Google NO se prueba aquí (requiere una cuenta).
"""

import json
from datetime import datetime, timedelta, timezone

import pytest

from home_geofence.findmydevice import (
    DEFAULT_TOOLS_DIR,
    REQUIRED_SECRETS,
    FindMyDeviceProvider,
    LocationReport,
    check_secrets_file,
    match_device,
    pick_best_report,
)
from home_geofence.geo import Sample
from home_geofence.providers import ProviderError

NOW = datetime(2026, 9, 17, 12, 0, tzinfo=timezone.utc)


def report(minutes_ago=0, own=False, acc=20.0):
    return LocationReport(latitude=-33.4, longitude=-70.6, timestamp=NOW - timedelta(minutes=minutes_ago),
                          accuracy_m=acc, status=1, is_own_report=own)


def write_secrets(tmp_path, **overrides):
    data = {k: f"valor-{k}" for k in REQUIRED_SECRETS}
    data.update(overrides)
    p = tmp_path / "secrets.json"
    p.write_text(json.dumps(data))
    return p


def test_check_secrets_ok(tmp_path):
    check_secrets_file(write_secrets(tmp_path))


def test_check_secrets_missing_file(tmp_path):
    with pytest.raises(ProviderError, match="No existe"):
        check_secrets_file(tmp_path / "nope.json")


def test_check_secrets_incomplete_names_missing_keys(tmp_path):
    p = write_secrets(tmp_path, owner_key="", shared_key=None)
    with pytest.raises(ProviderError) as exc:
        check_secrets_file(p)
    assert "owner_key" in str(exc.value) and "shared_key" in str(exc.value)


def test_check_secrets_invalid_json(tmp_path):
    p = tmp_path / "secrets.json"
    p.write_text("{oops")
    with pytest.raises(ProviderError, match="JSON"):
        check_secrets_file(p)


def test_pick_best_prefers_newest_then_own_report():
    assert pick_best_report([]) is None
    newest = report(minutes_ago=1)
    assert pick_best_report([report(10), newest, report(30)]) is newest
    own = report(minutes_ago=5, own=True)
    crowd = report(minutes_ago=5, own=False)
    assert pick_best_report([crowd, own]) is own


def test_match_device_by_name_case_insensitive_or_id():
    devices = [("Pixel de Juan", "abc123"), ("Auriculares", "def456")]
    assert match_device(devices, "pixel de juan ") == ("Pixel de Juan", "abc123")
    assert match_device(devices, "def456") == ("Auriculares", "def456")
    assert match_device(devices, "Otro") is None


def test_rate_limit_reuses_last_sample(monkeypatch, tmp_path):
    p = FindMyDeviceProvider(str(write_secrets(tmp_path)), "Pixel", min_request_interval_s=300)
    calls = []

    def fake_resolve():
        calls.append("resolve")
        return "Pixel", "id"

    monkeypatch.setattr(p, "_resolve_device", fake_resolve)
    monkeypatch.setattr(p, "_request_device_update", lambda cid: "update")
    monkeypatch.setattr(p, "_decrypt_reports", lambda upd: [report(1)])

    first = p.get_sample()
    assert isinstance(first, Sample) and first.latitude == -33.4
    second = p.get_sample()  # dentro del intervalo mínimo → misma muestra, sin nueva consulta
    assert second is first
    assert calls == ["resolve"]


def test_unexpected_error_is_wrapped_and_device_cache_cleared(monkeypatch, tmp_path):
    p = FindMyDeviceProvider(str(write_secrets(tmp_path)), "Pixel", min_request_interval_s=0)
    p._canonic = ("Pixel", "id")
    monkeypatch.setattr(p, "_request_device_update", lambda cid: (_ for _ in ()).throw(RuntimeError("red caída")))
    with pytest.raises(ProviderError, match="red caída"):
        p.get_sample()
    assert p._canonic is None


def test_no_reports_keeps_previous_sample(monkeypatch, tmp_path):
    p = FindMyDeviceProvider(str(write_secrets(tmp_path)), "Pixel", min_request_interval_s=0)
    monkeypatch.setattr(p, "_resolve_device", lambda: ("Pixel", "id"))
    monkeypatch.setattr(p, "_request_device_update", lambda cid: "update")
    monkeypatch.setattr(p, "_decrypt_reports", lambda upd: [report(1)])
    first = p.get_sample()
    monkeypatch.setattr(p, "_decrypt_reports", lambda upd: [])
    assert p.get_sample() is first


def test_missing_submodule_gives_clear_error(tmp_path):
    p = FindMyDeviceProvider(str(write_secrets(tmp_path)), "Pixel", tools_dir=str(tmp_path / "vacio"))
    with pytest.raises(ProviderError, match="git submodule update"):
        p.list_devices()


@pytest.mark.skipif(not (DEFAULT_TOOLS_DIR / "main.py").exists(), reason="submódulo GoogleFindMyTools no inicializado")
def test_vendored_tool_reads_our_secrets_file(tmp_path):
    """La herramienta debe leer/escribir NUESTRO secrets.json, no vendor/.../Auth/secrets.json."""
    pytest.importorskip("gpsoauth")
    pytest.importorskip("selenium")
    pytest.importorskip("pyscrypt")
    secrets = write_secrets(tmp_path, username="hijo@gmail.com")
    p = FindMyDeviceProvider(str(secrets), "Pixel")
    p._load()
    from Auth.token_cache import get_cached_value, set_cached_value

    assert get_cached_value("username") == "hijo@gmail.com"
    set_cached_value("prueba", "x")
    assert json.loads(secrets.read_text())["prueba"] == "x"
    assert not (DEFAULT_TOOLS_DIR / "Auth" / "secrets.json").exists()
