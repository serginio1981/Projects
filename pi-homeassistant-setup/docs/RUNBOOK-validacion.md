# RUNBOOK — Validación manual de pi-homeassistant-setup

Validación paso a paso tras instalar (o cuando algo se comporte raro). Cada
paso indica el **resultado esperado** y la **acción correctiva**.

> Criterio de éxito doble: **HA responde en el 8123 Y la impresión sigue
> operativa**. Si en cualquier paso descubres la impresión degradada, esa es
> la prioridad: ve directo a [ROLLBACK.md](ROLLBACK.md) si no la recuperas
> rápido.

---

## Paso 0 — Foto del estado ANTES de instalar

```bash
lpstat -p                        # colas y su estado
avahi-browse -rt _ipp._tcp | grep -c '^='   # cuántos anuncios AirPrint hay
free -m && df -h /
```

- **Resultado esperado:** cola(s) *idle/enabled*, al menos un anuncio
  `_ipp._tcp`, y las cifras de RAM/disco anotadas para comparar después.
- **Acción correctiva:** si la impresión ya estaba rota ANTES, arréglala
  primero; si no, cualquier diagnóstico posterior mezclará dos problemas.

## Paso 1 — Preflight

```bash
sudo ./scripts/00-preflight.sh
```

- **Resultado esperado:** "Sin rastro de Home Assistant OS/Supervised",
  servidor de impresión detectado, puerto 8123 libre, avisos (no errores)
  por RAM justa.
- **Acción correctiva:** si aborta por HA OS/Supervised, esta Pi no es apta
  para este proyecto (o esa instalación previa debe eliminarse a mano, fuera
  de este alcance). Si el 8123 está ocupado: `ss -tlnp | grep 8123` e
  identifica al ocupante.

## Paso 2 — Docker operativo

```bash
docker --version && docker compose version && sudo docker info | head -5
```

- **Resultado esperado:** versiones impresas y `docker info` sin errores.
- **Acción correctiva:** `sudo ./scripts/10-docker.sh` (idempotente);
  diagnóstico del daemon: `journalctl -u docker -n 50`.

## Paso 3 — Rotación de logs aplicada

```bash
cat /etc/docker/daemon.json
```

- **Resultado esperado:** `log-driver: json-file` con `max-size`/`max-file`.
  Si el archivo ya existía, tus claves previas siguen ahí (se fusiona, no se
  pisa) y hay un respaldo `.bak`.
- **Acción correctiva:** `sudo ./scripts/30-hardening-sd.sh`. Si el
  contenedor de HA ya existía al aplicar esto, recréalo para que tome la
  rotación: `sudo docker compose -f /opt/homeassistant/docker-compose.yml up -d --force-recreate`.

## Paso 4 — Contenedor de HA corriendo

```bash
sudo docker ps --filter name=homeassistant
sudo docker logs homeassistant --tail 20
```

- **Resultado esperado:** contenedor `Up`, y en los logs el arranque de HA
  sin tracebacks repetidos.
- **Acción correctiva:** `sudo ./scripts/20-homeassistant.sh`. Primer
  arranque lento es normal (WiFi + microSD); "exec format error" = imagen de
  arquitectura equivocada (¿Raspberry Pi OS de 32 bits?).

## Paso 5 — Interfaz de HA

Desde otro equipo: `http://<hostname>.local:8123`

- **Resultado esperado:** el asistente inicial de HA (crear usuario, nombre
  de la casa, ubicación). Complétalo.
- **Acción correctiva:** si no carga pero el paso 4 está bien, prueba por IP
  en vez de `.local`; revisa que estás en la misma red que la Pi.

## Paso 6 — LA IMPRESIÓN SIGUE VIVA (el paso que da sentido al proyecto)

```bash
lpstat -p
avahi-browse -rt _ipp._tcp | grep '^=' | grep -c 'rp=printers/'
```

Y la prueba real: imprime una página desde el iPhone.

- **Resultado esperado:** cola igual que en el paso 0, anuncio AirPrint
  visible, y la hoja sale de la impresora.
- **Acción correctiva:** si la impresión se degradó tras instalar HA:
  1. `sudo systemctl status cups avahi-daemon` — ¿siguen activos?
  2. ¿RAM agotada? `free -m`; si `available` está en dos dígitos, HA está
     asfixiando la Pi: considera parar HA temporalmente
     (`sudo docker stop homeassistant`) y verifica que la impresión vuelve.
  3. Si no vuelve ni con HA parado: [ROLLBACK.md](ROLLBACK.md).

## Paso 7 — Coexistencia mDNS (riesgo declarado)

```bash
avahi-browse -rt _ipp._tcp | grep '^=' | head -3
avahi-browse -rt _home-assistant._tcp | grep '^=' | head -3
avahi-browse -rt _hap._tcp | grep '^=' | head -3   # solo si configuraste HomeKit Bridge
```

- **Resultado esperado:** el anuncio AirPrint **y** el de HA visibles a la
  vez (el de `_hap._tcp` solo tras configurar HomeKit Bridge). Es la
  verificación empírica de que zeroconf de HA y Avahi conviven.
- **Acción correctiva:** si al aparecer los anuncios de HA desaparece el de
  AirPrint, reinicia avahi (`sudo systemctl restart avahi-daemon`) y repite.
  Si el conflicto persiste, es una limitación real: repórtala (issue en el
  repo) y como paliativo desactiva la integración HomeKit Bridge en HA y
  vuelve a comprobar.

## Paso 8 — Recorder acotado (desgaste de microSD)

```bash
cat /opt/homeassistant/config/recorder.yaml.example
```

- **Resultado esperado:** el bloque `recorder:` de ejemplo. Cópialo dentro
  de `/opt/homeassistant/config/configuration.yaml` (respetando que solo
  haya UNA clave `recorder:` en el archivo) y reinicia HA:
  `sudo docker restart homeassistant`.
- **Acción correctiva:** si HA no arranca tras editar, valida el YAML: en la
  interfaz **Herramientas para desarrolladores → YAML → Verificar
  configuración**, o revisa `sudo docker logs homeassistant --tail 30`.

## Paso 9 — Diagnóstico automatizado (en cualquier momento)

```bash
sudo ./scripts/90-verify.sh
```

- **Resultado esperado:** "ÉXITO: Home Assistant responde en el 8123 Y el
  servidor de impresión sigue operativo."

---

## Tabla de troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| Preflight aborta | HA OS/Supervised detectado | Esta Pi no es apta; no continúes |
| 8123 ocupado | Otro servicio previo | `ss -tlnp \| grep 8123` |
| `exec format error` en logs | Imagen incompatible (SO de 32 bits) | Reinstalar Pi OS de 64 bits |
| HA lentísimo / OOM | 2 GB al límite | `free -m`; no apiles servicios; considera SSD y swap moderado |
| Impresión degradada tras instalar | RAM agotada o avahi caído | Runbook paso 6 |
| Anuncio AirPrint desaparecido | Conflicto mDNS (raro) o avahi caído | Runbook paso 7 |
| iPhone no ve la impresora pero lpstat bien | mDNS: misma causa que arriba | Runbook paso 7 |
| Base de datos de HA gigante | Recorder sin acotar | Runbook paso 8 |
| Integración Matter: "Failed to connect" a ws://localhost:5580/ws | Falta el Matter Server (en Container no hay add-on) | `sudo ./scripts/40-matter-server.sh` y reintenta con la URL por defecto |
| Matter Server corre pero el emparejamiento falla | Se intenta desde Safari (imposible), o IPv6 filtrado en la LAN, o dispositivo Thread sin border router | Usar la app móvil oficial de HA; revisar IPv6 en el router; Thread requiere border router (fuera de alcance) |
| Tras actualizar HA no arranca | Imagen nueva con breaking change | `docker logs`; fija versión: `HA_IMAGE=ghcr.io/home-assistant/home-assistant:<versión>` y redespliega |
| microSD llena | Logs/imágenes acumuladas | `sudo docker system df`; `sudo docker image prune -f` |
