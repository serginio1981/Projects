# pi-wifi-failover

Activa la **WiFi de la Raspberry Pi automáticamente cuando no hay cable de
red**: al arrancar sin cable y también al desconectarlo en caliente. Al
volver a conectar el cable, la WiFi se apaga (o se mantiene, según el modo).

Proyecto independiente y autocontenido para **Raspberry Pi OS Bookworm o
posterior** (usa NetworkManager). No depende de ningún otro proyecto de este
repositorio.

## Por qué "no funcionaba" el WiFi con la imagen oficial

Este instalador corrige de paso las dos causas más comunes de una Pi headless
que nunca aparece en la red WiFi:

1. **País WiFi sin configurar** → Raspberry Pi OS deja la radio **bloqueada
   por rfkill** y el WiFi no funciona aunque la configuración sea correcta.
   El instalador fija el país (default `CL`) con `raspi-config nonint` y
   desbloquea la radio.
2. **Red de 5 GHz** → las Pi Zero W, 3B y anteriores **no tienen radio de
   5 GHz** y jamás verán una SSID solo-5G. El instalador escanea tras
   configurar y te avisa si tu SSID no es visible.

## Cómo funciona

```
              ┌──────────────────────────── Raspberry Pi ────────────────────┐
 cable puesto │ eth0 con carrier ──▶ dispatcher NM ──▶ wifi-failover check   │
 cable fuera  │ eth0 sin carrier ──▶ dispatcher NM ──▶   ├─ exclusive: radio │
 arranque     │ wifi-failover-boot.service (systemd) ──▶ │  on/off según     │
              │   (cubre el arranque SIN cable, sin      │  cable            │
              │    eventos de dispatcher)                └─ always: radio on │
              └────────────────────────────────────────────────────────────┘
```

Tres piezas, todas instaladas por `install.sh`:

| Pieza | Ruta instalada | Rol |
|---|---|---|
| Lógica | `/usr/local/sbin/wifi-failover` | Decide según el carrier de `eth0` |
| Dispatcher NM | `/etc/NetworkManager/dispatcher.d/90-wifi-failover` | Reacciona al poner/quitar el cable |
| Unidad systemd | `wifi-failover-boot.service` | Aplica el estado al arrancar (clave para el arranque sin cable) |
| Configuración | `/etc/default/wifi-failover` | Interfaces, perfil y modo |

## Instalación

```bash
cd pi-wifi-failover
sudo WIFI_SSID='MI_RED' ./install.sh      # la clave se pregunta oculta
```

Flags: `--dry-run`, `--yes`, `--help`. Desinstalación: `sudo ./uninstall.sh`
(con `--purge-profile` borra también el perfil WiFi guardado).

### Variables de entorno

| Variable | Default | Descripción |
|---|---|---|
| `WIFI_SSID` | *(se pregunta)* | Nombre de la red |
| `WIFI_PASSWORD` | *(se pregunta oculta)* | Clave en claro (no la PSK en hex) |
| `WIFI_COUNTRY` | `CL` | País WiFi; obligatorio para desbloquear la radio |
| `WIFI_PROFILE` | `wifi-failover` | Nombre del perfil en NetworkManager |
| `ETH_IFACE` / `WLAN_IFACE` | `eth0` / `wlan0` | Interfaces |
| `FAILOVER_MODE` | `exclusive` | Ver modos abajo |
| `ETH_WAIT_SECONDS` | `15` | Espera del enlace de cable al arrancar |

### Modos

- **`exclusive`** (default): WiFi encendida **solo** cuando no hay cable. Es
  lo pedido: la Pi usa cable si lo tiene, y WiFi si no.
- **`always`**: WiFi siempre encendida. Con cable puesto, el tráfico sale por
  el cable igualmente (NetworkManager da métrica 100 a ethernet y 600 a WiFi),
  y si el cable se desconecta el cambio es instantáneo, sin apagar/encender
  radios. Es el modo más robusto si no te importa tener ambas interfaces
  activas.

## Probarlo

1. Con el cable puesto: `nmcli radio wifi` debe decir `disabled` (modo
   exclusive).
2. Quita el cable: en ~10 s `nmcli radio wifi` pasa a `enabled` y
   `nmcli connection show --active` muestra el perfil `wifi-failover`.
3. La prueba de fuego: apaga la Pi, quita el cable, enciéndela y localízala
   en la WiFi (`ping raspberry1103.local` o la lista de clientes del router).
4. Registros del mecanismo: `journalctl -t wifi-failover`

## Troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| `rfkill list` muestra `Soft blocked: yes` | País WiFi sin fijar | Reejecuta el instalador o `sudo raspi-config nonint do_wifi_country CL` |
| El SSID no aparece en `nmcli device wifi list` | Red 5 GHz con Pi sin radio 5 GHz, o SSID mal escrito | Usa la SSID de 2.4 GHz; revisa mayúsculas/espacios |
| Conecta pero pide clave otra vez | Clave incorrecta (usa la clave en claro, no la PSK hex) | `sudo nmcli connection modify wifi-failover wifi-sec.psk 'clave'` |
| No hace nada al quitar el cable | Dispatcher sin permisos correctos (NM lo ignora en silencio) | `ls -l /etc/NetworkManager/dispatcher.d/90-wifi-failover` → debe ser `root:root` y `-rwxr-xr-x` |
| Al arrancar sin cable no hay WiFi | Unidad de arranque deshabilitada | `sudo systemctl enable --now wifi-failover-boot.service` |
| SSH por WiFi se corta al enchufar el cable | Comportamiento esperado en modo `exclusive` | Usa `FAILOVER_MODE=always` |

## Limitaciones conocidas

- Solo para imágenes con **NetworkManager** (Raspberry Pi OS Bookworm+,
  octubre 2023 en adelante). En Bullseye/dhcpcd el instalador se detiene con
  un mensaje claro en lugar de configurar a medias.
- En modo `exclusive` hay un corte de ~10 s al pasar de cable a WiFi
  (encendido de radio + asociación). El modo `always` lo elimina a cambio de
  mantener ambas interfaces activas.
- Si la Pi es un servidor (impresión/escaneo), recuerda que al cambiar de
  interfaz **cambia la IP**: usa el hostname `.local` (mDNS) o configura en el
  router la misma reserva DHCP para ambas MACs (la de eth0 y la de wlan0).
