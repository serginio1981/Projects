# virtual-caster

Consola de podcast/streaming virtual para Windows y iPad: 2 micrófonos con ganancia, EQ y fader, música,
soundpad de 8 pads, reverb, side chain, loop back y salidas separadas de transmisión y audífonos. Toma como
referencia la consola física Maono Maonocaster E2 Gen2.

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

El prototipo de iPad usa la misma disposición de consola que Windows y cubre un canal de micrófono (ganancia,
EQ, fader, mute, reverb con 6 presets), música desde archivo, soundpad, medidores y grabación de la mezcla. Los
controles aún no implementados en iPad aparecen atenuados. iPadOS no permite que una app actúe como micrófono de
otras apps; la mezcla sale por audífonos/jack/interfaz USB-C.

## Instaladores (GitHub Actions)

El workflow `.github/workflows/virtual-caster.yml` compila ambas apps en cada pull request y en cada cambio en
`main`, y deja los resultados como artefactos de la ejecución (pestaña **Actions** del repositorio):

| Artefacto | Contenido | Limitación |
|---|---|---|
| `VirtualCaster-Windows-Setup` | Instalador `.exe` (Inno Setup), autocontenido, x64 | **Sin firma de código**: Windows SmartScreen mostrará una advertencia al ejecutarlo |
| `VirtualCaster-iPad-unsigned-ipa` | `.ipa` de la app de iPad | **Sin firmar: no se puede instalar directamente en un iPad** |

Para publicar una versión con ambos archivos adjuntos en un Release, crea una etiqueta con el formato
`virtual-caster-vX.Y.Z`.

### Sobre el instalador de iPad

Apple exige que toda app instalada en un iPad esté firmada. Un `.ipa` instalable requiere una cuenta del
Apple Developer Program (de pago), un certificado de distribución y un perfil de aprovisionamiento, guardados
como secretos del repositorio. Mientras eso no exista, el workflow solo puede producir el `.ipa` sin firmar,
que sirve para comprobar que la app compila y como base para firmarlo después. La alternativa sin cuenta de
pago es abrir el proyecto en Xcode (en un Mac) e instalarlo en tu propio iPad con un Apple ID gratuito.

En un Mac, el proyecto de Xcode se genera con:

```bash
brew install xcodegen
```

```bash
cd virtual-caster/ipad && xcodegen generate
```
