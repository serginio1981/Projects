# pi-airplay-speaker

Convierte la Raspberry Pi en un **receptor AirPlay** con
[shairport-sync](https://github.com/mikebrady/shairport-sync) (paquete
oficial de Debian/Raspberry Pi OS): el iPhone/iPad/Mac la ve en el menú
AirPlay y le envía la música. Es la pata "parlante" de la emulación parcial
de un HomePod; el resto (automatizaciones, app Casa, voz) lo cubre Home
Assistant.

Proyecto independiente, mismo patrón de la casa: instalador idempotente,
`--dry-run`, mensajes en español, y verificación de que **AirPrint sigue
publicado** después de instalar (comparte el mismo avahi-daemon).

## Requisito físico ineludible

La Pi necesita **un parlante conectado**: jack de 3.5mm, TV/monitor por HDMI
con audio, o parlante/DAC USB. Sin salida física de audio, el iPhone
"enviará" la música y no sonará nada.

## Instalación

```bash
cd pi-airplay-speaker
sudo ./install.sh                 # nombre por defecto: "Parlante Pi"
```

Con nombre y salida específicos:

```bash
sudo AIRPLAY_NAME='Parlante Living' AUDIO_DEVICE='hw:Headphones' ./install.sh --yes
```

| Variable | Default | Descripción |
|---|---|---|
| `AIRPLAY_NAME` | `Parlante Pi` | Nombre en el menú AirPlay |
| `AUDIO_DEVICE` | *(vacío = default del sistema)* | Dispositivo ALSA; mira `aplay -l`. Jack de la Pi: `hw:Headphones` |

Flags: `--dry-run`, `--yes`, `--help`. Desinstalar: `sudo ./uninstall.sh`
(restaura la configuración original y no toca avahi ni la impresión).

## Uso desde el iPhone

Centro de Control → mantén presionado el grupo de música → icono **AirPlay**
→ elige el nombre configurado. También desde Música, Spotify, YouTube, etc.
(cualquier app con salida AirPlay).

## Limitaciones conocidas

- **AirPlay clásico (v1) según el paquete de la distribución.** El iPhone lo
  ve y le envía audio sin problema; lo que no hace AirPlay 1 es audio
  multi-habitación sincronizado con parlantes AirPlay 2. Las compilaciones
  de shairport-sync con AirPlay 2 existen (requieren `nqptp`), pero
  compilarlas queda fuera de este instalador; el script reporta qué variante
  quedó instalada.
- **Solo audio.** AirPlay de video/pantalla no está en el alcance de
  shairport-sync.
- La calidad de la salida por el jack 3.5mm de la Pi es funcional pero
  modesta; un DAC USB barato mejora bastante.
- El volumen inicial de ALSA puede venir bajo o muteado: ajústalo con
  `alsamixer` (F6 para elegir tarjeta).

## Convivencia con el resto de la Pi

shairport-sync consume muy poca RAM y usa el avahi-daemon ya existente — el
mismo que anuncia AirPrint y que usa Home Assistant. El instalador verifica
al final que el anuncio `_ipp._tcp` de la impresora sigue visible. Un
anuncio mDNS más (`_raop._tcp`) no interfiere con los demás.
