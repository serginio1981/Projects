"""Bucle principal: consulta la ubicación, alimenta la geocerca y avisa."""

from __future__ import annotations

import json
import logging
import signal
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from .config import Config
from .geo import Event, GeofenceTracker, Transition, Zone
from .notifiers import (
    ConsoleNotifier,
    EmailNotifier,
    Notifier,
    TelegramNotifier,
    broadcast,
)
from .providers import (
    FileProvider,
    GoogleMapsSharingProvider,
    LocationProvider,
    ProviderError,
)

log = logging.getLogger(__name__)


def build_provider(cfg: Config) -> LocationProvider:
    if cfg.google:
        return GoogleMapsSharingProvider(cfg.google.cookies_file, cfg.google.account_email, cfg.google.person)
    assert cfg.file_provider_path  # garantizado por load_config
    return FileProvider(cfg.file_provider_path)


def build_notifiers(cfg: Config) -> list[Notifier]:
    notifiers: list[Notifier] = []
    if cfg.console:
        notifiers.append(ConsoleNotifier())
    if cfg.telegram:
        notifiers.append(TelegramNotifier(cfg.telegram.bot_token, cfg.telegram.chat_id))
    if cfg.email:
        e = cfg.email
        notifiers.append(EmailNotifier(e.host, e.port, e.username, e.password, e.sender, e.recipients, e.use_starttls))
    return notifiers


def build_tracker(cfg: Config) -> GeofenceTracker:
    h = cfg.home
    return GeofenceTracker(
        home_lat=h.latitude,
        home_lon=h.longitude,
        radius_m=h.radius_m,
        hysteresis_m=h.hysteresis_m,
        confirm_samples=h.confirm_samples,
        max_accuracy_m=h.max_accuracy_m,
        max_age_s=None if h.max_age_min is None else h.max_age_min * 60,
    )


def in_quiet_hours(quiet: Optional[tuple[int, int]], now: Optional[datetime] = None) -> bool:
    """True si la hora local actual cae dentro de [from, to). Soporta rangos que cruzan medianoche."""
    if not quiet:
        return False
    start, end = quiet
    hour = (now or datetime.now()).hour
    if start == end:
        return False
    if start < end:
        return start <= hour < end
    return hour >= start or hour < end


def format_message(cfg: Config, event: Event) -> tuple[str, str]:
    name = cfg.child_name
    when = event.sample.timestamp.astimezone().strftime("%H:%M")
    if event.transition == Transition.ENTERED:
        title = f"🏠 {name} llegó a casa"
    else:
        title = f"🚶 {name} salió de casa"
    lines = [f"Hora de la posición: {when}", f"Distancia a casa: {event.distance_m:.0f} m"]
    if event.sample.accuracy_m is not None:
        lines.append(f"Precisión GPS: ±{event.sample.accuracy_m:.0f} m")
    if event.sample.address:
        lines.append(f"Dirección: {event.sample.address}")
    if event.sample.battery_level is not None:
        lines.append(f"Batería del teléfono: {event.sample.battery_level}%")
    return title, "\n".join(lines)


class StateStore:
    """Persiste la última zona conocida para no re-avisar tras un reinicio."""

    def __init__(self, path: Optional[str]) -> None:
        self.path = Path(path) if path else None

    def load(self) -> Zone:
        if not self.path or not self.path.exists():
            return Zone.UNKNOWN
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return Zone(data.get("zone", Zone.UNKNOWN.value))
        except (ValueError, OSError):
            log.warning("Fichero de estado ilegible, se ignora: %s", self.path)
            return Zone.UNKNOWN

    def save(self, zone: Zone) -> None:
        if not self.path:
            return
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(json.dumps({"zone": zone.value, "saved_at": datetime.now().isoformat()}), encoding="utf-8")
        except OSError:
            log.exception("No se pudo guardar el estado en %s", self.path)


class Monitor:
    def __init__(self, cfg: Config, provider: LocationProvider, notifiers: list[Notifier], tracker: GeofenceTracker,
                 state: Optional[StateStore] = None) -> None:
        self.cfg = cfg
        self.provider = provider
        self.notifiers = notifiers
        self.tracker = tracker
        self.state = state or StateStore(cfg.state_file)
        self._stop = False
        self._consecutive_errors = 0
        self.tracker.zone = self.state.load()
        if self.tracker.zone != Zone.UNKNOWN:
            log.info("Estado restaurado: %s estaba %s", cfg.child_name,
                     "en casa" if self.tracker.zone == Zone.INSIDE else "fuera de casa")

    def stop(self, *_: object) -> None:
        self._stop = True

    def tick(self) -> Optional[Event]:
        """Una iteración: consulta, procesa y avisa si toca. Devuelve el evento o None."""
        try:
            sample = self.provider.get_sample()
            self._consecutive_errors = 0
        except ProviderError as exc:
            self._consecutive_errors += 1
            log.error("No se pudo obtener la ubicación (%d seguidos): %s", self._consecutive_errors, exc)
            return None

        if sample is None:
            log.warning("%s no aparece entre las personas que comparten ubicación contigo", self.cfg.child_name)
            return None

        previous_zone = self.tracker.zone
        event = self.tracker.process(sample)
        log.info("%s a %.0f m de casa (±%s m) · zona=%s%s", self.cfg.child_name, event.distance_m,
                 f"{sample.accuracy_m:.0f}" if sample.accuracy_m is not None else "?", event.zone.value,
                 f" · {event.reason}" if event.reason else "")

        if event.zone != previous_zone:
            self.state.save(event.zone)

        if event.transition is None:
            return event
        if event.transition == Transition.LEFT and not self.cfg.notify_on_leave:
            log.info("Salida detectada pero notify.on_leave=false; no se avisa")
            return event
        if in_quiet_hours(self.cfg.quiet_hours):
            log.info("Transición %s en horas de silencio; no se avisa", event.transition.value)
            return event

        title, body = format_message(self.cfg, event)
        failed = broadcast(self.notifiers, title, body)
        if failed:
            log.warning("%d canal(es) de aviso fallaron", failed)
        return event

    def run_forever(self) -> None:
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        log.info("Monitor iniciado: casa=(%.5f, %.5f) radio=%.0f m cada %d s",
                 self.tracker.home_lat, self.tracker.home_lon, self.tracker.radius_m, self.cfg.poll_interval_s)
        while not self._stop:
            self.tick()
            # Backoff suave si Google falla repetidamente (p. ej. cookies caducadas).
            delay = self.cfg.poll_interval_s * min(2 ** max(self._consecutive_errors - 1, 0), 16)
            for _ in range(int(delay)):
                if self._stop:
                    break
                time.sleep(1)
        log.info("Monitor detenido")
