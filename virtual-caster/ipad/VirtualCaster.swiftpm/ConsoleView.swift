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

struct ConsoleView: View {
    @StateObject private var caster = CasterEngine()
    @State private var importTarget: ImportTarget?
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                micPanel
                padPanel
                outputPanel
            }
        }
        .padding()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            guard case .success(let url) = result, let target = importTarget else { return }
            switch target {
            case .music: caster.playMusic(url: url)
            case .pad(let i): caster.loadPad(i, url: url)
            }
        }
    }

    private var header: some View {
        HStack {
            Button(caster.running ? "■ Apagar" : "▶ Encender") {
                caster.running ? caster.stop() : caster.start()
            }
            .buttonStyle(.borderedProminent)
            Button(caster.recording ? "● Detener grabación" : "● Grabar mezcla") { caster.toggleRecording() }
                .buttonStyle(.bordered)
                .disabled(!caster.running)
            Text(caster.status).font(.footnote).foregroundStyle(.orange)
            Spacer()
            Text("OUTPUT").font(.caption2)
            ProgressView(value: Double(caster.outputDb + 60), total: 60)
                .frame(width: 220)
                .tint(caster.outputDb > -3 ? .red : .green)
        }
    }

    private var micPanel: some View {
        panel("MICRÓFONO") {
            knob("GAIN (dB)", $caster.gainDb, -20...20)
            knob("LOW", $caster.lowDb, -10...10)
            knob("MID", $caster.midDb, -10...10)
            knob("HI", $caster.highDb, -10...10)
            knob("FADER", $caster.fader, 0...1)
            Toggle("MUTE", isOn: $caster.muted).toggleStyle(.button)
        }
    }

    private var padPanel: some View {
        panel("SOUNDPAD — toca para reproducir, mantén presionado para cargar un archivo") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                ForEach(0..<CasterEngine.padCount, id: \.self) { i in
                    Text("PAD \(i + 1)")
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(Color.white.opacity(0.85))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { caster.triggerPad(i) }
                        .onLongPressGesture { importTarget = .pad(i); showImporter = true }
                }
            }
            knob("PAD VOL", $caster.padLevel, 0...1)
            HStack {
                Button("Cargar música…") { importTarget = .music; showImporter = true }
                Button("Detener música") { caster.stopMusic() }
            }
            .buttonStyle(.bordered)
            knob("MUSIC", $caster.musicLevel, 0...1)
        }
    }

    private var outputPanel: some View {
        panel("SALIDA Y EFECTOS") {
            knob("OUTPUT", $caster.outputLevel, 0...1)
            Toggle("DRY / WET (reverb)", isOn: $caster.reverbOn).toggleStyle(.button)
            knob("REVERB", $caster.reverbAmount, 0...1)
            Picker("REVERB PRESETS", selection: $caster.reverbPreset) {
                ForEach(0..<CasterEngine.presetNames.count, id: \.self) { i in
                    Text(CasterEngine.presetNames[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.13))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func knob(_ label: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: range)
        }
    }
}
