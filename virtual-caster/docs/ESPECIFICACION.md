# VirtualCaster — especificación y arquitectura

Consola de podcast/streaming **virtual** para Windows y iPad, que reproduce por software las funciones de una
consola física de sobremesa (2 entradas de micrófono, música, soundpad, efectos y salidas de transmisión/audífonos).

> **Origen de la información.** El inventario de funciones se obtuvo **únicamente de la fotografía** del equipo
> (rótulos del panel superior y trasero). No se consultó el manual del fabricante ni se identificó el modelo
> exacto. Donde el comportamiento no es evidente por el rótulo, está marcado como **(supuesto)** y debe
> validarse contra el manual o el equipo real.

## 1. Decisiones tomadas

| Tema | Decisión |
|---|---|
| Alcance | Mezclador real por software: procesa audio real, reemplaza a la consola física |
| Salida hacia otras apps (Windows) | Mediante un cable virtual de terceros instalado aparte (p. ej. VB-CABLE); sin driver propio |
| Tecnología | Nativo por plataforma: C# + WASAPI (NAudio) en Windows; Swift + AVAudioEngine en iPad |
| Entregable | Esta especificación + prototipo funcional |

## 2. Inventario de funciones de la consola física

### Panel superior

| Control | Función | Windows (prototipo) | iPad (prototipo) |
|---|---|---|---|
| GAIN 1 / GAIN 2 | Ganancia de entrada de cada micrófono | ✅ ±20 dB | ✅ un solo canal |
| LOW / MID / HI | EQ de 3 bandas, ±10 dB | ✅ común a ambos micrófonos (supuesto) | ✅ |
| HEADPHONE | Nivel de audífonos | ✅ | — (una sola salida) |
| MUSIC (perilla grande) | Nivel de la música (AUX/BT/USB) | ✅ | ✅ |
| OUTPUT (perilla grande) | Nivel de la mezcla de salida | ✅ | ✅ |
| Fader 1 / 2 | Nivel de cada micrófono | ✅ | ✅ un solo canal |
| Mute 1 / 2 | Silencia cada micrófono | ✅ | ✅ |
| 48V 1 / 2 | Alimentación phantom | ⛔ no aplica | ⛔ no aplica |
| SOUNDPAD (8 pads) | Dispara clips de audio | ✅ tonos de fábrica o archivo | ✅ |
| PAD VOL | Nivel del soundpad | ✅ | ✅ |
| BT | Entrada de audio por Bluetooth | ⏳ fase 2 | ⏳ por evaluar |
| MONITOR | Escuchar los micrófonos en audífonos (supuesto) | ✅ | — |
| REVERB + REVERB PRESETS | Cantidad y tipo de reverberación | ✅ 4 presets | ✅ 4 presets |
| DRY/WET | Activa/desactiva la reverb en la voz (supuesto) | ✅ | ✅ |
| SIDE CHAIN | Baja la música al hablar (ducking) | ✅ | ⏳ fase 2 |
| SING ALONG | Atenúa la voz principal de la música (supuesto) | ✅ cancelación de centro | ⏳ fase 2 |
| LOOP BACK | Incluye el audio del computador en la transmisión | ✅ | ⛔ no posible (ver §4) |
| NOISE REDUCER | Reducción de ruido | ✅ puerta de ruido (aproximación) | ⏳ fase 2 |
| PITCH | Cambio de tono de la voz | ⏳ fase 2 | ⏳ fase 2 |
| AUTO-TUNE + selector de tonalidad (A…Ab) | Corrección de afinación | ⏳ fase 2 | ⏳ fase 2 |
| Medidores (MUSIC, 1, 2, SOUNDPAD, HEADPHONES, OUTPUT) | Nivel por señal | ✅ los 6 | ✅ solo OUTPUT |
| Indicador de batería | Carga de la batería interna | ⛔ no aplica | ⛔ no aplica |

### Panel trasero y frontal

| Conector | Equivalente virtual |
|---|---|
| 2 × entrada combo XLR/jack (mic / instrumento) | Dispositivo de captura del sistema + selección de canal |
| Hi-Z (entrada 2) | ⛔ no aplica: es una característica eléctrica de la interfaz física |
| AUX IN | Dispositivo de captura asignado a "Música" |
| STREAM OUT 1 / 2 | Dispositivo de salida "Transmisión" (cable virtual en Windows) |
| MONITOR SPK / 2 × audífonos | Dispositivo de salida "Audífonos" |
| USB-C (audio hacia/desde el computador) | Cable virtual (salida) + LOOP BACK (entrada) |
| DC 5V, encendido, luz | ⛔ no aplica |

**Lo que el software no puede reemplazar:** preamplificadores, alimentación 48 V, Hi-Z y conectores XLR. Para
micrófonos XLR o instrumentos sigue siendo necesaria una interfaz de audio USB; la app trabaja con lo que el
sistema operativo expone como dispositivo de audio (interfaz USB-C, micrófono USB, jack, micrófono integrado).

## 3. Flujo de señal (motor de Windows)

```
Mic 1 ─► GAIN ─► puerta de ruido ─► EQ ─► fader ─► mute ─┐
Mic 2 ─► GAIN ─► puerta de ruido ─► EQ ─► fader ─► mute ─┴─► voz ─┬─────────────► (seca)
                                                                  └─► REVERB ───► (húmeda × cantidad)
Música ─► SING ALONG ─► nivel MUSIC ─► SIDE CHAIN (controlado por la voz)
Pads ──► PAD VOL
Sistema (LOOP BACK)

Transmisión = (voz + reverb + música + pads [+ sistema]) × OUTPUT    ─► limitador ─► cable virtual
Audífonos   = (música + pads [+ voz + reverb si MONITOR]) × HEADPHONE ─► limitador ─► audífonos
```

Formato interno: 48 kHz, float de 32 bits, estéreo.

## 4. Arquitectura y restricciones por plataforma

### Windows

- `VirtualCaster.Core` (.NET 8, sin dependencias): todo el DSP y el motor de mezcla. Es independiente de la
  plataforma y tiene pruebas unitarias.
- `VirtualCaster.App` (WPF + NAudio/WASAPI): selección de dispositivos, interfaz y enlace con WASAPI en modo
  compartido. El dispositivo de audífonos actúa como reloj maestro.
- **Micrófono virtual:** la app no crea dispositivos de audio. La mezcla se envía a la entrada de un cable
  virtual (p. ej. "CABLE Input" de VB-CABLE) y la otra aplicación (OBS, Teams, Zoom) elige la salida del
  cable ("CABLE Output") como micrófono.
- **LOOP BACK:** captura lo que suena en un dispositivo de salida. Ese dispositivo no puede ser el de
  audífonos ni el de transmisión, porque se capturaría la propia salida de la consola (eco/realimentación);
  la app lo valida al encender. Solución de fase 2: captura por proceso con exclusión de la propia app
  (disponible en versiones recientes de Windows 10/11; **verificar la versión mínima exacta en la documentación
  de Microsoft**).
- **Riesgos conocidos:** (a) cada dispositivo tiene su propio reloj; sin corrección de deriva pueden aparecer
  clics ocasionales en sesiones largas; (b) el modo compartido de WASAPI agrega latencia — la cifra real debe
  medirse en el equipo de destino, no hay una medición hecha; (c) el remuestreo de entrada es por
  interpolación lineal (calidad de prototipo).

### iPad

- App SwiftUI + `AVAudioEngine` con nodos estándar (EQ, reverb, mezcladores, reproductores).
- **Una app de iPadOS no puede presentarse como micrófono para otras apps** ni capturar el audio de otras
  apps; por eso no hay equivalente a STREAM OUT ni a LOOP BACK. La mezcla sale por la ruta de audio activa
  (audífonos, jack o interfaz USB-C) y puede grabarse a archivo. Enviar la mezcla a otro equipo exige una
  interfaz USB-C o un cable desde la salida de audífonos.
- iPadOS expone **una sola ruta de entrada activa** a la vez. Dos micrófonos independientes requieren una
  interfaz USB de 2 o más canales y separar los canales en la app (fase 2).
- Funciones sin nodo estándar (side chain, puerta de ruido, sing along) requieren DSP propio; ver §5.

## 5. Plan por fases

1. **Fase 1 — prototipo (este entregable).** Motor Windows con pruebas, app WPF, app iPad básica.
2. **Fase 2 — paridad funcional.** PITCH y AUTO-TUNE; reducción de ruido real (p. ej. RNNoise — verificar
   licencia y disponibilidad); entrada Bluetooth; LOOP BACK por proceso; 2 canales en iPad; presets y
   persistencia de configuración; perillas giratorias y aspecto fiel a la consola.
3. **Fase 3 — robustez.** Corrección de deriva de reloj, modo exclusivo/baja latencia, manejo de
   conexión/desconexión de dispositivos, instalador, publicación (Microsoft Store / App Store).

**Decisión pendiente para la fase 2:** hoy el DSP existe dos veces (C# en Windows, nodos de Apple en iPad), por
lo que ambas apps no suenan idéntico. Si se requiere paridad exacta, conviene mover el DSP a una biblioteca
C/C++ compartida invocada desde C# y Swift.

## 6. Estado de verificación

| Componente | Estado |
|---|---|
| `VirtualCaster.Core` | Compilado y con 20 pruebas unitarias aprobadas (en Linux, .NET 8) |
| `AudioHost.cs` (enlace WASAPI) | Compilado contra NAudio 2.2.1; **no ejecutado** (requiere Windows y dispositivos de audio) |
| Ventana WPF (`MainWindow`) | **No compilada ni ejecutada**: el SDK de escritorio de Windows no estaba disponible en el entorno de desarrollo. Solo se validó que el XAML es XML bien formado y que los nombres coinciden con el código |
| App iPad | **No compilada ni ejecutada**: no había toolchain de Apple disponible |

Ningún componente ha sido probado todavía con audio real.
