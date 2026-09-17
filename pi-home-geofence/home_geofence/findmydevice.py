"""Proveedor de ubicación basado en la red *Find My Device / Find Hub* de Google.

Google no publica una API para localizar un teléfono desde Find Hub. Este
módulo se apoya en el proyecto de ingeniería inversa **GoogleFindMyTools**
(GPLv3, https://github.com/leonboe1/GoogleFindMyTools), incluido como
submódulo git en ``vendor/GoogleFindMyTools`` y fijado a un commit concreto.

Cómo funciona una consulta (es lo mismo que hace ``main.py`` de la
herramienta, pero devolviendo datos en vez de imprimirlos):

1. ``ListDevices`` → lista de dispositivos de la cuenta y su *canonic id*.
2. ``ExecuteAction/LocateTracker`` → Google responde **por push (FCM)**, así
   que la herramienta mantiene un receptor FCM en un hilo de fondo y
   esperamos la respuesta con un tiempo máximo.
3. Los informes vienen cifrados de extremo a extremo; se descifran con la
   *owner key* de la cuenta, que la herramienta guarda en ``secrets.json``.

Limitaciones importantes (no son de este proyecto, sino del método):

* La autenticación necesita **Chrome en un PC** (no funciona en ARM Linux
  según el README de la herramienta). Se hace una vez en el PC y se copia
  ``secrets.json`` a la Pi. Aquí se comprueba que el fichero contiene todo
  lo necesario antes de usarlo, para que en la Pi **nunca** se intente abrir
  Chrome ni pedir datos por teclado.
* Los dispositivos son los de la cuenta con la que se autenticó. Para ver el
  teléfono del hijo hay que autenticarse **con la cuenta del hijo**.
* Cada consulta dispara una localización en la red de Google; la integración
  de Home Assistant que usa esta misma técnica recomienda no bajar de
  5 minutos entre consultas. ``min_request_interval_s`` lo garantiza.
"""

from __future__ import annotations

import hashlib
import json
import logging
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .geo import Sample
from .providers import LocationProvider, ProviderError

log = logging.getLogger(__name__)

DEFAULT_TOOLS_DIR = Path(__file__).resolve().parent.parent / "vendor" / "GoogleFindMyTools"

# Claves que main.py deja en secrets.json tras un ciclo completo (listar +
# localizar un dispositivo). Sin ellas la herramienta intentaría abrir Chrome.
REQUIRED_SECRETS = ("username", "aas_token", "fcm_credentials", "shared_key", "owner_key")


@dataclass(frozen=True)
class LocationReport:
    latitude: float
    longitude: float
    timestamp: datetime
    accuracy_m: Optional[float]
    status: int
    is_own_report: bool


def check_secrets_file(path: Path) -> None:
    """Falla con un mensaje claro si secrets.json no sirve para uso headless."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ProviderError(f"No existe {path}. Genera secrets.json en un PC con Chrome (ver README) y cópialo aquí.")
    except json.JSONDecodeError as exc:
        raise ProviderError(f"{path} no es JSON válido: {exc}")
    missing = [k for k in REQUIRED_SECRETS if not data.get(k)]
    if missing:
        raise ProviderError(
            f"{path} está incompleto (faltan: {', '.join(missing)}). En el PC, ejecuta main.py de "
            "GoogleFindMyTools, lista los dispositivos y localiza UNO al menos una vez; eso rellena las claves."
        )


def pick_best_report(reports: list[LocationReport]) -> Optional[LocationReport]:
    """El informe más reciente con coordenadas; a igual fecha, el propio del teléfono."""
    if not reports:
        return None
    return max(reports, key=lambda r: (r.timestamp, r.is_own_report))


def match_device(devices: list[tuple[str, str]], wanted: str) -> Optional[tuple[str, str]]:
    """Busca por nombre (sin distinguir mayúsculas) o por canonic id exacto."""
    w = wanted.strip().casefold()
    for name, canonic_id in devices:
        if canonic_id == wanted.strip() or (name and name.strip().casefold() == w):
            return name, canonic_id
    return None


class FindMyDeviceProvider(LocationProvider):
    def __init__(
        self,
        secrets_file: str,
        device: str,
        tools_dir: Optional[str] = None,
        request_timeout_s: float = 60.0,
        min_request_interval_s: float = 300.0,
    ) -> None:
        self.secrets_file = Path(secrets_file).expanduser().resolve()
        self.device = device
        self.tools_dir = Path(tools_dir).expanduser().resolve() if tools_dir else DEFAULT_TOOLS_DIR
        self.request_timeout_s = request_timeout_s
        self.min_request_interval_s = min_request_interval_s
        self._lib: Optional[dict] = None
        self._canonic: Optional[tuple[str, str]] = None
        self._last_request_at: float = 0.0
        self._last_sample: Optional[Sample] = None

    # ------------------------------------------------------------ carga lib
    def _load(self) -> dict:
        """Importa GoogleFindMyTools desde el submódulo y redirige su secrets.json."""
        if self._lib is not None:
            return self._lib
        if not (self.tools_dir / "main.py").exists():
            raise ProviderError(
                f"No se encuentra GoogleFindMyTools en {self.tools_dir}. Ejecuta: git submodule update --init"
            )
        check_secrets_file(self.secrets_file)
        if str(self.tools_dir) not in sys.path:
            sys.path.insert(0, str(self.tools_dir))
        try:
            from Auth import token_cache
            from Auth.fcm_receiver import FcmReceiver
            from FMDNCrypto.foreign_tracker_cryptor import decrypt as decrypt_foreign
            from KeyBackup.cloud_key_decryptor import decrypt_aes_gcm
            from NovaApi.ExecuteAction.LocateTracker.decrypt_locations import is_mcu_tracker, retrieve_identity_key
            from NovaApi.ExecuteAction.LocateTracker.location_request import create_location_request
            from NovaApi.ListDevices.nbe_list_devices import request_device_list
            from NovaApi.nova_request import nova_request
            from NovaApi.scopes import NOVA_ACTION_API_SCOPE
            from NovaApi.util import generate_random_uuid
            from ProtoDecoders import Common_pb2, DeviceUpdate_pb2
            from ProtoDecoders.decoder import get_canonic_ids, parse_device_list_protobuf, parse_device_update_protobuf
        except ImportError as exc:
            raise ProviderError(
                f"Faltan dependencias de GoogleFindMyTools ({exc}). Instala: pip install -r requirements-fmd.txt"
            ) from exc

        # token_cache construye la ruta con os.path.join(<dir del módulo>, SECRETS_FILE);
        # con una ruta absoluta os.path.join descarta el directorio, así que la
        # herramienta lee y escribe NUESTRO fichero sin copiarlo dentro del submódulo.
        token_cache.SECRETS_FILE = str(self.secrets_file)
        if token_cache._get_secrets_file() != str(self.secrets_file):  # noqa: SLF001
            raise ProviderError("GoogleFindMyTools cambió cómo localiza secrets.json; revisa findmydevice.py")

        self._lib = dict(
            FcmReceiver=FcmReceiver, decrypt_foreign=decrypt_foreign, decrypt_aes_gcm=decrypt_aes_gcm,
            is_mcu_tracker=is_mcu_tracker, retrieve_identity_key=retrieve_identity_key,
            create_location_request=create_location_request, request_device_list=request_device_list,
            nova_request=nova_request, NOVA_ACTION_API_SCOPE=NOVA_ACTION_API_SCOPE,
            generate_random_uuid=generate_random_uuid, Common_pb2=Common_pb2, DeviceUpdate_pb2=DeviceUpdate_pb2,
            get_canonic_ids=get_canonic_ids, parse_device_list_protobuf=parse_device_list_protobuf,
            parse_device_update_protobuf=parse_device_update_protobuf,
        )
        return self._lib

    # ------------------------------------------------------------ Google
    def list_devices(self) -> list[tuple[str, str]]:
        lib = self._load()
        result_hex = lib["request_device_list"]()
        if not result_hex:
            raise ProviderError("Google no devolvió la lista de dispositivos (¿token caducado? revisa el log)")
        return lib["get_canonic_ids"](lib["parse_device_list_protobuf"](result_hex))

    def _resolve_device(self) -> tuple[str, str]:
        if self._canonic is None:
            devices = self.list_devices()
            found = match_device(devices, self.device)
            if not found:
                names = ", ".join(repr(n) for n, _ in devices) or "(ninguno)"
                raise ProviderError(f"El dispositivo {self.device!r} no está en la cuenta. Disponibles: {names}")
            self._canonic = found
            log.info("Find My Device: %r → canonic id %s", found[0], found[1])
        return self._canonic

    def _request_device_update(self, canonic_id: str):
        lib = self._load()
        request_uuid = lib["generate_random_uuid"]()
        done = threading.Event()
        holder: dict = {}

        def on_response(hex_payload: str) -> None:
            try:
                update = lib["parse_device_update_protobuf"](hex_payload)
            except Exception:  # noqa: BLE001
                log.debug("Push FCM no parseable", exc_info=True)
                return
            if update.fcmMetadata.requestUuid == request_uuid:
                holder["update"] = update
                done.set()

        receiver = lib["FcmReceiver"]()
        fcm_token = receiver.register_for_location_updates(on_response)
        try:
            payload = lib["create_location_request"](canonic_id, fcm_token, request_uuid)
            if lib["nova_request"](lib["NOVA_ACTION_API_SCOPE"], payload) is None:
                raise ProviderError("Google rechazó la petición de localización (ver mensaje [NovaRequest] en el log)")
            if not done.wait(self.request_timeout_s):
                raise ProviderError(f"Sin respuesta de Google en {self.request_timeout_s:.0f} s "
                                    "(¿teléfono apagado o sin red?)")
        finally:
            try:
                receiver.location_update_callbacks.remove(on_response)
            except ValueError:
                pass
        return holder["update"]

    def _decrypt_reports(self, update) -> list[LocationReport]:
        lib = self._load()
        Common_pb2, DeviceUpdate_pb2 = lib["Common_pb2"], lib["DeviceUpdate_pb2"]
        registration = update.deviceMetadata.information.deviceRegistration
        try:
            identity_key = lib["retrieve_identity_key"](registration)
        except SystemExit:  # la herramienta hace exit(1) si la clave no descifra
            raise ProviderError("No se pudo descifrar la clave del dispositivo: la owner key de secrets.json "
                                "no coincide (¿reiniciaste el cifrado E2EE?). Regenera secrets.json en el PC.")

        reports_proto = update.deviceMetadata.information.locationInformation.reports.recentLocationAndNetworkLocations
        locations = list(reports_proto.networkLocations)
        times = list(reports_proto.networkLocationTimestamps)
        if reports_proto.HasField("recentLocation"):
            locations.append(reports_proto.recentLocation)
            times.append(reports_proto.recentLocationTimestamp)

        is_mcu = lib["is_mcu_tracker"](registration)
        out: list[LocationReport] = []
        for loc, ts in zip(locations, times):
            if loc.status == Common_pb2.Status.SEMANTIC:
                continue  # "en casa", "en el trabajo"... sin coordenadas
            encrypted = loc.geoLocation.encryptedReport.encryptedLocation
            public_key_random = loc.geoLocation.encryptedReport.publicKeyRandom
            try:
                if public_key_random == b"":
                    plain = lib["decrypt_aes_gcm"](hashlib.sha256(identity_key).digest(), encrypted)
                else:
                    offset = 0 if is_mcu else loc.geoLocation.deviceTimeOffset
                    plain = lib["decrypt_foreign"](identity_key, encrypted, public_key_random, offset)
            except Exception:  # noqa: BLE001
                log.warning("Informe de ubicación no descifrable; se ignora", exc_info=True)
                continue
            proto_loc = DeviceUpdate_pb2.Location()
            proto_loc.ParseFromString(plain)
            out.append(LocationReport(
                latitude=proto_loc.latitude / 1e7,
                longitude=proto_loc.longitude / 1e7,
                timestamp=datetime.fromtimestamp(int(ts.seconds), tz=timezone.utc),
                accuracy_m=float(loc.geoLocation.accuracy) if loc.geoLocation.accuracy else None,
                status=int(loc.status),
                is_own_report=bool(loc.geoLocation.encryptedReport.isOwnReport),
            ))
        return out

    # ------------------------------------------------------------ API
    def get_sample(self) -> Optional[Sample]:
        since = time.monotonic() - self._last_request_at
        if self._last_sample is not None and since < self.min_request_interval_s:
            log.debug("Find My Device: reutilizando última posición (%.0f s < %.0f s)", since, self.min_request_interval_s)
            return self._last_sample
        try:
            name, canonic_id = self._resolve_device()
            update = self._request_device_update(canonic_id)
            reports = self._decrypt_reports(update)
        except ProviderError:
            raise
        except Exception as exc:  # noqa: BLE001 - red, tokens, protobuf...
            self._canonic = None
            raise ProviderError(f"Error consultando Find My Device: {exc}") from exc
        finally:
            self._last_request_at = time.monotonic()

        best = pick_best_report(reports)
        if best is None:
            log.warning("Find My Device no devolvió coordenadas para %r", name)
            return self._last_sample
        self._last_sample = Sample(
            latitude=best.latitude, longitude=best.longitude, timestamp=best.timestamp, accuracy_m=best.accuracy_m,
        )
        return self._last_sample

    def describe_people(self) -> list[str]:
        return [f"- nombre={name!r} canonic_id={cid}" for name, cid in self.list_devices()]
