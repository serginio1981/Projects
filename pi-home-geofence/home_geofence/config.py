"""Carga y validación de la configuración YAML."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

import yaml


class ConfigError(ValueError):
    pass


@dataclass
class HomeConfig:
    latitude: float
    longitude: float
    radius_m: float = 100.0
    hysteresis_m: float = 50.0
    confirm_samples: int = 2
    max_accuracy_m: Optional[float] = 250.0
    max_age_min: Optional[float] = 15.0


@dataclass
class GoogleConfig:
    cookies_file: str
    account_email: str
    person: str


@dataclass
class FindMyDeviceConfig:
    secrets_file: str
    device: str
    tools_dir: Optional[str] = None
    request_timeout_s: float = 60.0
    min_request_interval_s: float = 300.0


@dataclass
class HomeAssistantConfig:
    webhook_url: str


@dataclass
class TelegramConfig:
    bot_token: str
    chat_id: str


@dataclass
class EmailConfig:
    host: str
    port: int
    username: str
    password: str
    sender: str
    recipients: list[str]
    use_starttls: bool = True


@dataclass
class Config:
    child_name: str
    home: HomeConfig
    google: Optional[GoogleConfig] = None
    find_my_device: Optional[FindMyDeviceConfig] = None
    file_provider_path: Optional[str] = None
    poll_interval_s: int = 60
    notify_on_leave: bool = True
    quiet_hours: Optional[tuple[int, int]] = None  # (desde, hasta) en hora local, 0-23
    telegram: Optional[TelegramConfig] = None
    email: Optional[EmailConfig] = None
    home_assistant: Optional[HomeAssistantConfig] = None
    console: bool = True
    state_file: Optional[str] = None
    log_level: str = "INFO"
    extra: dict[str, Any] = field(default_factory=dict)


def _expand(value: Any) -> Any:
    """Permite ``${VAR}`` en cualquier string del YAML (secretos fuera del fichero)."""
    if isinstance(value, str):
        return os.path.expandvars(os.path.expanduser(value))
    if isinstance(value, dict):
        return {k: _expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_expand(v) for v in value]
    return value


def _require(section: dict, key: str, where: str) -> Any:
    if key not in section or section[key] in (None, ""):
        raise ConfigError(f"Falta '{key}' en la sección '{where}' del config")
    return section[key]


def load_config(path: str | Path) -> Config:
    path = Path(path)
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except FileNotFoundError as exc:
        raise ConfigError(f"No existe el fichero de configuración {path}") from exc
    except yaml.YAMLError as exc:
        raise ConfigError(f"YAML inválido en {path}: {exc}") from exc
    raw = _expand(raw)

    home_raw = raw.get("home") or {}
    home = HomeConfig(
        latitude=float(_require(home_raw, "latitude", "home")),
        longitude=float(_require(home_raw, "longitude", "home")),
        radius_m=float(home_raw.get("radius_m", 100)),
        hysteresis_m=float(home_raw.get("hysteresis_m", 50)),
        confirm_samples=int(home_raw.get("confirm_samples", 2)),
        max_accuracy_m=(None if home_raw.get("max_accuracy_m") is None else float(home_raw["max_accuracy_m"])),
        max_age_min=(None if home_raw.get("max_age_min") is None else float(home_raw["max_age_min"])),
    )

    google = None
    if raw.get("google"):
        g = raw["google"]
        google = GoogleConfig(
            cookies_file=str(_require(g, "cookies_file", "google")),
            account_email=str(_require(g, "account_email", "google")),
            person=str(_require(g, "person", "google")),
        )
    fmd = None
    if raw.get("find_my_device"):
        f = raw["find_my_device"]
        fmd = FindMyDeviceConfig(
            secrets_file=str(_require(f, "secrets_file", "find_my_device")),
            device=str(_require(f, "device", "find_my_device")),
            tools_dir=(str(f["tools_dir"]) if f.get("tools_dir") else None),
            request_timeout_s=float(f.get("request_timeout_s", 60)),
            min_request_interval_s=float(f.get("min_request_interval_s", 300)),
        )
    file_provider_path = (raw.get("file_provider") or {}).get("path")
    sources = [name for name, present in (("google", google), ("find_my_device", fmd),
                                          ("file_provider", file_provider_path)) if present]
    if not sources:
        raise ConfigError("Configura una fuente: 'google', 'find_my_device' o 'file_provider' (pruebas)")
    if len(sources) > 1:
        raise ConfigError(f"Configura una sola fuente de ubicación, no varias: {', '.join(sources)}")

    notif = raw.get("notify") or {}
    home_assistant = None
    if notif.get("home_assistant"):
        h = notif["home_assistant"]
        home_assistant = HomeAssistantConfig(webhook_url=str(_require(h, "webhook_url", "notify.home_assistant")))
    telegram = None
    if notif.get("telegram"):
        t = notif["telegram"]
        telegram = TelegramConfig(bot_token=str(_require(t, "bot_token", "notify.telegram")),
                                  chat_id=str(_require(t, "chat_id", "notify.telegram")))
    email = None
    if notif.get("email"):
        e = notif["email"]
        recipients = e.get("recipients") or []
        if isinstance(recipients, str):
            recipients = [recipients]
        email = EmailConfig(
            host=str(_require(e, "host", "notify.email")),
            port=int(e.get("port", 587)),
            username=str(e.get("username", "")),
            password=str(e.get("password", "")),
            sender=str(_require(e, "sender", "notify.email")),
            recipients=[str(r) for r in recipients],
            use_starttls=bool(e.get("use_starttls", True)),
        )

    quiet = notif.get("quiet_hours")
    quiet_hours = None
    if quiet:
        try:
            quiet_hours = (int(quiet["from"]), int(quiet["to"]))
        except (KeyError, TypeError, ValueError) as exc:
            raise ConfigError("notify.quiet_hours debe tener 'from' y 'to' (0-23)") from exc

    return Config(
        child_name=str(raw.get("child_name") or (google.person if google else fmd.device if fmd else "hijo")),
        home=home,
        google=google,
        find_my_device=fmd,
        file_provider_path=file_provider_path,
        poll_interval_s=int(raw.get("poll_interval_s", 60)),
        notify_on_leave=bool(notif.get("on_leave", True)),
        quiet_hours=quiet_hours,
        telegram=telegram,
        email=email,
        home_assistant=home_assistant,
        console=bool(notif.get("console", True)),
        state_file=raw.get("state_file"),
        log_level=str(raw.get("log_level", "INFO")).upper(),
    )
