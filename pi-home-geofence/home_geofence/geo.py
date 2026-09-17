"""Cálculo de distancias y máquina de estados de la geocerca.

Este módulo no depende de Google ni de la red: recibe muestras de posición
y decide cuándo la persona ha ENTRADO o SALIDO de la zona de casa.

Para evitar falsas alarmas se aplican tres filtros:

* **Histéresis**: se entra con ``radius_m`` y se sale con
  ``radius_m + hysteresis_m``. Así una posición que oscila en el borde no
  genera entradas/salidas en cadena.
* **Confirmación**: un cambio de estado solo se acepta tras
  ``confirm_samples`` muestras consecutivas que lo respalden.
* **Calidad de la muestra**: se descartan posiciones con precisión peor que
  ``max_accuracy_m`` o más antiguas que ``max_age_s``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

EARTH_RADIUS_M = 6_371_000.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Distancia en metros entre dos coordenadas (fórmula de haversine)."""
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


class Zone(str, Enum):
    UNKNOWN = "unknown"
    INSIDE = "inside"
    OUTSIDE = "outside"


class Transition(str, Enum):
    ENTERED = "entered"
    LEFT = "left"


@dataclass(frozen=True)
class Sample:
    """Una lectura de posición de la persona monitoreada."""

    latitude: float
    longitude: float
    timestamp: datetime
    accuracy_m: Optional[float] = None
    address: Optional[str] = None
    battery_level: Optional[int] = None

    def age_s(self, now: Optional[datetime] = None) -> float:
        now = now or datetime.now(timezone.utc)
        return (now - self.timestamp).total_seconds()


@dataclass
class Event:
    """Resultado de procesar una muestra."""

    transition: Optional[Transition]
    zone: Zone
    distance_m: float
    sample: Sample
    reason: str = ""


@dataclass
class GeofenceTracker:
    home_lat: float
    home_lon: float
    radius_m: float = 100.0
    hysteresis_m: float = 50.0
    confirm_samples: int = 2
    max_accuracy_m: Optional[float] = 250.0
    max_age_s: Optional[float] = 15 * 60

    zone: Zone = Zone.UNKNOWN
    _pending_zone: Optional[Zone] = field(default=None, repr=False)
    _pending_count: int = field(default=0, repr=False)

    def __post_init__(self) -> None:
        if self.radius_m <= 0:
            raise ValueError("radius_m debe ser > 0")
        if self.hysteresis_m < 0:
            raise ValueError("hysteresis_m no puede ser negativa")
        if self.confirm_samples < 1:
            raise ValueError("confirm_samples debe ser >= 1")

    # ------------------------------------------------------------------ API
    def distance_to_home(self, sample: Sample) -> float:
        return haversine_m(self.home_lat, self.home_lon, sample.latitude, sample.longitude)

    def classify(self, distance_m: float) -> Zone:
        """Zona *instantánea* de una distancia, aplicando histéresis según el estado actual."""
        if self.zone == Zone.INSIDE:
            return Zone.INSIDE if distance_m <= self.radius_m + self.hysteresis_m else Zone.OUTSIDE
        return Zone.INSIDE if distance_m <= self.radius_m else Zone.OUTSIDE

    def is_usable(self, sample: Sample, now: Optional[datetime] = None) -> tuple[bool, str]:
        if self.max_accuracy_m is not None and sample.accuracy_m is not None and sample.accuracy_m > self.max_accuracy_m:
            return False, f"precisión insuficiente ({sample.accuracy_m:.0f} m > {self.max_accuracy_m:.0f} m)"
        if self.max_age_s is not None:
            age = sample.age_s(now)
            if age > self.max_age_s:
                return False, f"muestra antigua ({age / 60:.0f} min)"
        return True, ""

    def process(self, sample: Sample, now: Optional[datetime] = None) -> Event:
        """Procesa una muestra y devuelve el evento (con o sin transición)."""
        distance = self.distance_to_home(sample)
        usable, why = self.is_usable(sample, now)
        if not usable:
            return Event(None, self.zone, distance, sample, reason=why)

        observed = self.classify(distance)

        if observed == self.zone:
            # Estado estable: se descarta cualquier cambio pendiente.
            self._pending_zone, self._pending_count = None, 0
            return Event(None, self.zone, distance, sample)

        if self.zone == Zone.UNKNOWN:
            # Primera fijación tras arrancar: se acepta de inmediato y no se
            # reporta transición (no sabemos de dónde venía).
            self.zone = observed
            return Event(None, self.zone, distance, sample, reason="estado inicial")

        if self._pending_zone == observed:
            self._pending_count += 1
        else:
            self._pending_zone, self._pending_count = observed, 1

        if self._pending_count < self.confirm_samples:
            return Event(None, self.zone, distance, sample,
                         reason=f"pendiente {observed.value} ({self._pending_count}/{self.confirm_samples})")

        self.zone = observed
        self._pending_zone, self._pending_count = None, 0
        transition = Transition.ENTERED if observed == Zone.INSIDE else Transition.LEFT
        return Event(transition, self.zone, distance, sample)
