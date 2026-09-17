"""Fuentes de ubicación.

Solo hay una fuente "real": la ubicación que tu hijo comparte contigo desde
Google Maps (*Compartir ubicación*). Google no ofrece una API pública para
esto, así que se usa la librería no oficial ``locationsharinglib``, que lee
el mismo endpoint que usa la web de Google Maps autenticándose con las
cookies de TU cuenta (la del padre/madre), nunca con la cuenta del hijo.

``FileProvider`` existe para probar el monitor sin Google: lee un JSON con
``latitude``, ``longitude``, ``accuracy`` y ``timestamp`` (ISO-8601).
"""

from __future__ import annotations

import json
import logging
from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .geo import Sample

log = logging.getLogger(__name__)


class ProviderError(RuntimeError):
    """Error recuperable al obtener la ubicación (red, sesión caducada, etc.)."""


class LocationProvider(ABC):
    @abstractmethod
    def get_sample(self) -> Optional[Sample]:
        """Devuelve la última posición conocida, o None si la persona no comparte."""

    def describe_people(self) -> list[str]:  # pragma: no cover - solo informativo
        return []


class GoogleMapsSharingProvider(LocationProvider):
    """Lee la ubicación compartida en Google Maps mediante locationsharinglib."""

    def __init__(self, cookies_file: str, account_email: str, person: str) -> None:
        self.cookies_file = cookies_file
        self.account_email = account_email
        self.person = person
        self._service = None

    def _get_service(self):
        if self._service is None:
            try:
                from locationsharinglib import Service
                from locationsharinglib.locationsharinglibexceptions import (
                    InvalidCookieFile,
                    InvalidCookies,
                    InvalidData,
                )
            except ImportError as exc:  # pragma: no cover
                raise ProviderError("Falta la dependencia 'locationsharinglib' (pip install -r requirements.txt)") from exc
            try:
                self._service = Service(cookies_file=self.cookies_file, authenticating_account=self.account_email)
            except (InvalidCookieFile, InvalidCookies, InvalidData) as exc:
                raise ProviderError(f"No se pudo iniciar sesión con las cookies: {exc}") from exc
        return self._service

    def _find_person(self):
        service = self._get_service()
        wanted = self.person.strip().casefold()
        for p in service.get_all_people():
            for candidate in (p.nickname, p.full_name, p.id):
                if candidate and str(candidate).strip().casefold() == wanted:
                    return p
        return None

    def get_sample(self) -> Optional[Sample]:
        try:
            person = self._find_person()
        except ProviderError:
            raise
        except Exception as exc:  # red, parseo, sesión caducada...
            # Se descarta la sesión para que el próximo intento la reconstruya.
            self._service = None
            raise ProviderError(f"Error consultando Google Maps: {exc}") from exc

        if person is None:
            return None
        if person.latitude is None or person.longitude is None:
            return None
        return Sample(
            latitude=float(person.latitude),
            longitude=float(person.longitude),
            timestamp=person.datetime,
            accuracy_m=float(person.accuracy) if person.accuracy is not None else None,
            address=person.address,
            battery_level=person.battery_level,
        )

    def describe_people(self) -> list[str]:
        service = self._get_service()
        lines = []
        for p in service.get_all_people():
            lines.append(
                f"- nickname={p.nickname!r} full_name={p.full_name!r} id={p.id!r} "
                f"lat={p.latitude} lon={p.longitude} acc={p.accuracy} m fecha={p.datetime}"
            )
        return lines


class FileProvider(LocationProvider):
    """Lee la posición de un fichero JSON. Útil para pruebas y simulaciones."""

    def __init__(self, path: str) -> None:
        self.path = Path(path)

    def get_sample(self) -> Optional[Sample]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except json.JSONDecodeError as exc:
            raise ProviderError(f"JSON inválido en {self.path}: {exc}") from exc
        ts = data.get("timestamp")
        if ts:
            timestamp = datetime.fromisoformat(str(ts))
            if timestamp.tzinfo is None:
                timestamp = timestamp.replace(tzinfo=timezone.utc)
        else:
            timestamp = datetime.now(timezone.utc)
        return Sample(
            latitude=float(data["latitude"]),
            longitude=float(data["longitude"]),
            timestamp=timestamp,
            accuracy_m=float(data["accuracy"]) if data.get("accuracy") is not None else None,
            address=data.get("address"),
            battery_level=data.get("battery_level"),
        )
