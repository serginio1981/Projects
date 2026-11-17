# virtual-caster

Consola de podcast/streaming virtual para Windows y iPad: 2 micrófonos con ganancia, EQ y fader, música,
soundpad de 8 pads, reverb, side chain, loop back y salidas separadas de transmisión y audífonos.

**Estado: prototipo sin probar con audio real.** Ver el detalle en
[docs/ESPECIFICACION.md](docs/ESPECIFICACION.md) (funciones, arquitectura, limitaciones y estado de verificación).

## Windows

Requisitos: Windows 10/11 y el SDK de .NET 8. Para entregar la mezcla a OBS/Teams/Zoom, un cable de audio
virtual instalado aparte (p. ej. VB-CABLE).

```bash
cd windows
```

```bash
dotnet test VirtualCaster.Core.Tests
```

```bash
dotnet run --project VirtualCaster.App
```

Uso:

1. Elige el micrófono (y el canal, si es una interfaz de varios canales), los audífonos y, en
   "Transmisión", la entrada del cable virtual.
2. Pulsa **Encender**. En la otra aplicación selecciona la salida del cable virtual como micrófono.
3. **MONITOR** permite oírte en los audífonos. Usa audífonos, no parlantes, para evitar acoples.
4. Pads: clic para reproducir/detener; clic derecho para cargar un archivo de audio.
5. **LOOP BACK** necesita un dispositivo de "Audio del sistema" distinto de audífonos y transmisión.

## iPad

`ipad/VirtualCaster.swiftpm` es un paquete de app para Swift Playgrounds (en el iPad) o Xcode (en un Mac).
Si el paquete no abre, crea un proyecto "App" nuevo, copia `CasterEngine.swift` y `ConsoleView.swift`, y
agrega el permiso de micrófono (`NSMicrophoneUsageDescription`).

El prototipo de iPad cubre un canal de micrófono (ganancia, EQ, fader, mute, reverb), música desde archivo,
soundpad, medidor de salida y grabación de la mezcla. iPadOS no permite que una app actúe como micrófono de
otras apps; la mezcla sale por audífonos/jack/interfaz USB-C.
