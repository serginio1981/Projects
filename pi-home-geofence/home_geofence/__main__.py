"""Punto de entrada: ``python -m home_geofence --config config.yaml``."""

from __future__ import annotations

import argparse
import logging
import sys

from . import __version__
from .config import ConfigError, load_config
from .monitor import Monitor, build_notifiers, build_provider, build_tracker
from .notifiers import broadcast
from .providers import ProviderError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="home_geofence",
                                     description="Avisa cuando tu hijo llega a casa (o sale) usando la ubicación de "
                                                 "Google (compartida en Maps o de Find My Device).")
    parser.add_argument("-c", "--config", default="config.yaml", help="ruta del YAML (default: config.yaml)")
    parser.add_argument("--once", action="store_true", help="consulta una sola vez y termina")
    parser.add_argument("--list-people", "--list-devices", dest="list_people", action="store_true",
                        help="muestra las personas (google) o dispositivos (find_my_device) disponibles")
    parser.add_argument("--test-notify", action="store_true", help="envía un aviso de prueba por todos los canales")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args(argv)

    try:
        cfg = load_config(args.config)
    except ConfigError as exc:
        print(f"Error de configuración: {exc}", file=sys.stderr)
        return 2

    logging.basicConfig(level=getattr(logging, cfg.log_level, logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    log = logging.getLogger("home_geofence")

    if args.test_notify:
        failed = broadcast(build_notifiers(cfg), f"✅ Prueba de aviso ({cfg.child_name})",
                           "Si lees esto, el monitor puede avisarte por este canal.",
                           {"name": cfg.child_name, "event": "test", "latitude": cfg.home.latitude,
                            "longitude": cfg.home.longitude, "distance_m": 0})
        return 1 if failed else 0

    try:
        provider = build_provider(cfg)
        if args.list_people:
            lines = provider.describe_people()
            print("\n".join(lines) if lines else "No hay personas ni dispositivos disponibles en esta cuenta.")
            return 0
        monitor = Monitor(cfg, provider, build_notifiers(cfg), build_tracker(cfg))
        if args.once:
            event = monitor.tick()
            return 0 if event is not None else 1
        monitor.run_forever()
    except ProviderError as exc:
        log.error("%s", exc)
        return 1
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
