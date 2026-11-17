import SwiftUI
import UniformTypeIdentifiers

@main
struct VirtualCasterApp: App {
    var body: some Scene {
        WindowGroup {
            ConsoleView()
                .preferredColorScheme(.dark)
        }
    }
}

private enum ImportTarget: Equatable {
    case music
    case pad(Int)
}

/// Pantalla principal: barra de conexiones arriba y, debajo, el cuerpo de la consola con la misma
/// disposición que la versión de Windows. Los controles que el motor de iPad aún no implementa
/// (segundo micrófono, monitor, side chain, etc.) se muestran atenuados.
struct ConsoleView: View {
    @StateObject private var caster = CasterEngine()
    @State private var importTarget: ImportTarget?
    @State private var showImporter = false
    @State private var unused: Float = 0
    @State private var unusedFader: Float = 0.8
    @State private var unusedLevel: Float = 0.7

    private let designWidth: CGFloat = 1160
    private let designHeight: CGFloat = 620

    var body: some View {
        VStack(spacing: 10) {
            header
            GeometryReader { geo in
                let scale = min(geo.size.width / designWidth, geo.size.height / designHeight)
                console
                    .frame(width: designWidth, height: designHeight)
                    .scaleEffect(scale)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(12)
        .background(Color(white: 0.055).ignoresSafeArea())
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result, let target = importTarget else { return }
            switch target {
            case .music: caster.playMusic(url: url)
            case .pad(let i): caster.loadPad(i, url: url)
            }
        }
    }

    // MARK: - Barra superior

    private var header: some View {
        HStack(spacing: 10) {
            Button(caster.running ? "■ Apagar" : "▶ Encender") {
                if caster.running { caster.stop() } else { caster.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Skin.accent)
            Button(caster.recording ? "● Detener grabación" : "● Grabar mezcla") { caster.toggleRecording() }
                .buttonStyle(.bordered)
                .disabled(!caster.running)
            Button("Cargar música…") { importTarget = .music; showImporter = true }
                .buttonStyle(.bordered)
            Button("Detener música") { caster.stopMusic() }
                .buttonStyle(.bordered)
            Text(caster.status)
                .font(.footnote)
                .foregroundColor(Skin.accent)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Cuerpo de la consola

    private var console: some View {
        HStack(alignment: .top, spacing: 14) {
            leftColumn.frame(width: 250)
            centerColumn
            rightColumn.frame(width: 290)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .frame(width: designWidth, height: designHeight)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(LinearGradient(colors: [Color(white: 0.165), Color(white: 0.086)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(white: 0.23), lineWidth: 2))
    }

    private func bigKnob(_ title: String, _ value: Binding<Float>, defaultValue: Float) -> some View {
        VStack(spacing: 0) {
            Knob(value: value, range: 0...1, defaultValue: defaultValue, size: 170)
            HStack {
                ConsoleLabel("MIN")
                Spacer()
                ConsoleLabel(title, size: 13)
                Spacer()
                ConsoleLabel("MAX")
            }
            .frame(width: 170)
        }
    }

    private var leftColumn: some View {
        VStack(spacing: 14) {
            bigKnob("MUSIC", $caster.musicLevel, defaultValue: 0.7)
            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    Fader(value: $caster.fader).frame(width: 80, height: 250)
                    CapButton(title: "MUTE 1", color: Skin.red, isOn: caster.muted) { caster.muted.toggle() }
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: 6) {
                    Fader(value: $unusedFader, enabled: false).frame(width: 80, height: 250)
                    CapButton(title: "MUTE 2", color: Skin.red, enabled: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var centerColumn: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                LabeledKnob(title: "GAIN 1", value: $caster.gainDb, range: -20...20)
                LabeledKnob(title: "GAIN 2", value: $unused, range: -20...20, enabled: false)
                LabeledKnob(title: "LOW", value: $caster.lowDb, range: -10...10)
                LabeledKnob(title: "MID", value: $caster.midDb, range: -10...10)
                LabeledKnob(title: "HI", value: $caster.highDb, range: -10...10)
                LabeledKnob(title: "HEADPHONE", value: $unusedLevel, range: 0...1, enabled: false)
            }
            HStack(spacing: 0) {
                LabeledMeter(title: "MUSIC", db: caster.musicDb)
                LabeledMeter(title: "1", db: caster.micDb)
                LabeledMeter(title: "2", db: -60)
                LabeledMeter(title: "SOUNDPAD", db: caster.padDb)
                LabeledMeter(title: "HEADPHONES", db: -60)
                LabeledMeter(title: "OUTPUT", db: caster.outputDb)
            }
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.047)))
            HStack(spacing: 10) {
                CapButton(title: "48V", color: Skin.white, enabled: false)
                CapButton(title: "48V", color: Skin.white, enabled: false)
                CapButton(title: "BT", color: Skin.blue, enabled: false)
                CapButton(title: "MONITOR", color: Skin.blue, enabled: false)
                CapButton(title: "AUTO-TUNE", color: Skin.white, enabled: false)
            }
            Text("SOUNDPAD  ·  toca: reproducir / detener  ·  mantén presionado: cargar archivo")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Skin.accent)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(0..<CasterEngine.padCount, id: \.self) { i in
                    Text("PAD \(i + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(white: 0.19))
                        .frame(maxWidth: .infinity, minHeight: 78)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Skin.white))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black, lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { caster.triggerPad(i) }
                        .onLongPressGesture { importTarget = .pad(i); showImporter = true }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var rightColumn: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topTrailing) {
                bigKnob("OUTPUT", $caster.outputLevel, defaultValue: 0.8)
                    .frame(maxWidth: .infinity)
                Text("VirtualCaster")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Skin.accent)
            }
            HStack(spacing: 0) {
                LabeledKnob(title: "PAD VOL", value: $caster.padLevel, range: 0...1, defaultValue: 0.7)
                LabeledKnob(title: "PITCH", value: $unused, range: -12...12, enabled: false)
                LabeledKnob(title: "REVERB", value: $caster.reverbAmount, range: 0...1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 10), count: 3), spacing: 10) {
                CapButton(title: "REVERB\n\(CasterEngine.presetNames[caster.reverbPreset])", color: Skin.green, isOn: true) {
                    caster.cycleReverbPreset()
                }
                CapButton(title: "SIDE\nCHAIN", color: Skin.blue, enabled: false)
                CapButton(title: "SING\nALONG", color: Skin.red, enabled: false)
                CapButton(title: "DRY/WET", color: Skin.green, enabled: false)
                CapButton(title: "LOOP\nBACK", color: Skin.blue, enabled: false)
                CapButton(title: "NOISE\nREDUCER", color: Skin.red, enabled: false)
            }
            Spacer(minLength: 0)
        }
    }
}
