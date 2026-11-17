import AVFoundation
import Combine

/// Motor de la consola en iPad, construido con nodos estándar de AVAudioEngine.
///
/// Grafo:  entrada ─► EQ (ganancia + 3 bandas) ─► reverb ─► micMixer (fader/mute) ─┐
///         música (archivo) ───────────────────────────────────────────────────────┼─► mainMixer ─► salida
///         8 pads ─► padMixer ─────────────────────────────────────────────────────┘
///
/// Limitaciones del prototipo (ver docs/ESPECIFICACION.md): un solo canal de micrófono,
/// sin SIDE CHAIN, NOISE REDUCER, SING ALONG ni LOOP BACK.
final class CasterEngine: ObservableObject {
    static let padCount = 8

    private let engine = AVAudioEngine()
    private let micEQ = AVAudioUnitEQ(numberOfBands: 3)
    private let reverb = AVAudioUnitReverb()
    private let micMixer = AVAudioMixerNode()
    private let musicPlayer = AVAudioPlayerNode()
    private let padMixer = AVAudioMixerNode()
    private let padPlayers = (0..<CasterEngine.padCount).map { _ in AVAudioPlayerNode() }
    private var padBuffers = [AVAudioPCMBuffer?](repeating: nil, count: CasterEngine.padCount)
    private let padFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private var recordingFile: AVAudioFile?
    private var graphBuilt = false

    @Published var running = false
    @Published var recording = false
    @Published var status = "Apagada"
    @Published var outputDb: Float = -60

    // Perillas y botones
    @Published var gainDb: Float = 0 { didSet { micEQ.globalGain = gainDb } }
    @Published var lowDb: Float = 0 { didSet { micEQ.bands[0].gain = lowDb } }
    @Published var midDb: Float = 0 { didSet { micEQ.bands[1].gain = midDb } }
    @Published var highDb: Float = 0 { didSet { micEQ.bands[2].gain = highDb } }
    @Published var fader: Float = 0.8 { didSet { applyMic() } }
    @Published var muted = false { didSet { applyMic() } }
    @Published var reverbOn = false { didSet { applyReverb() } }
    @Published var reverbAmount: Float = 0.3 { didSet { applyReverb() } }
    @Published var reverbPreset = 2 { didSet { applyReverb() } }
    @Published var musicLevel: Float = 0.7 { didSet { musicPlayer.volume = musicLevel } }
    @Published var padLevel: Float = 0.7 { didSet { padMixer.outputVolume = padLevel } }
    @Published var outputLevel: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = outputLevel } }

    static let presetNames = ["Sala", "Estudio", "Hall", "Catedral"]
    private static let presets: [AVAudioUnitReverbPreset] = [.smallRoom, .mediumRoom, .largeHall, .cathedral]

    // MARK: - Encendido / apagado

    func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { self.status = "Sin permiso de micrófono"; return }
                do {
                    try self.configureSession()
                    self.buildGraphIfNeeded()
                    try self.engine.start()
                    self.running = true
                    self.status = "Encendida"
                } catch {
                    self.status = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        stopRecording()
        engine.stop()
        running = false
        status = "Apagada"
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord: entrada (micrófono integrado, jack o interfaz USB-C) y salida simultáneas.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
    }

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }
        graphBuilt = true

        let low = micEQ.bands[0], mid = micEQ.bands[1], high = micEQ.bands[2]
        low.filterType = .lowShelf; low.frequency = 120
        mid.filterType = .parametric; mid.frequency = 1500; mid.bandwidth = 1.0
        high.filterType = .highShelf; high.frequency = 8000
        for band in micEQ.bands { band.bypass = false; band.gain = 0 }

        engine.attach(micEQ); engine.attach(reverb); engine.attach(micMixer)
        engine.attach(musicPlayer); engine.attach(padMixer)
        padPlayers.forEach { engine.attach($0) }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        engine.connect(input, to: micEQ, format: inputFormat)
        engine.connect(micEQ, to: reverb, format: inputFormat)
        engine.connect(reverb, to: micMixer, format: nil)
        engine.connect(micMixer, to: engine.mainMixerNode, format: nil)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: nil)
        padPlayers.forEach { engine.connect($0, to: padMixer, format: padFormat) }
        engine.connect(padMixer, to: engine.mainMixerNode, format: nil)

        let main = engine.mainMixerNode
        main.installTap(onBus: 0, bufferSize: 1024, format: main.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        loadFactoryTones()
        applyMic(); applyReverb()
        micEQ.globalGain = gainDb
        musicPlayer.volume = musicLevel
        padMixer.outputVolume = padLevel
        main.outputVolume = outputLevel
    }

    private func applyMic() { micMixer.outputVolume = muted ? 0 : fader * fader }

    private func applyReverb() {
        reverb.loadFactoryPreset(Self.presets[reverbPreset])
        reverb.wetDryMix = reverbOn ? reverbAmount * 100 : 0
    }

    // MARK: - Medidor y grabación

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        if let file = recordingFile { try? file.write(from: buffer) }
        guard let data = buffer.floatChannelData else { return }
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[ch][i])) }
        }
        let db = peak > 0.000_001 ? 20 * log10(peak) : -60
        DispatchQueue.main.async { self.outputDb = max(-60, db) }
    }

    /// Graba la mezcla final en Documentos (equivalente práctico a STREAM OUT en iPad).
    func toggleRecording() {
        if recording { stopRecording(); return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "mezcla-\(Int(Date().timeIntervalSince1970)).caf"
        do {
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            recordingFile = try AVAudioFile(forWriting: docs.appendingPathComponent(name), settings: format.settings)
            recording = true
            status = "Grabando \(name)"
        } catch {
            status = "Error al grabar: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recordingFile = nil
        recording = false
        status = running ? "Encendida" : "Apagada"
    }

    // MARK: - Música y pads

    func playMusic(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            musicPlayer.stop()
            engine.disconnectNodeOutput(musicPlayer)
            engine.connect(musicPlayer, to: engine.mainMixerNode, format: file.processingFormat)
            musicPlayer.scheduleFile(file, at: nil, completionHandler: nil)
            if running { musicPlayer.play() }
        } catch {
            status = "No se pudo abrir la música: \(error.localizedDescription)"
        }
    }

    func stopMusic() { musicPlayer.stop() }

    func triggerPad(_ index: Int) {
        guard running, let buffer = padBuffers[index] else { return }
        let player = padPlayers[index]
        if player.isPlaying { player.stop(); return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    func loadPad(_ index: Int, url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
            try file.read(into: buffer)
            let player = padPlayers[index]
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: padMixer, format: buffer.format)
            padBuffers[index] = buffer
        } catch {
            status = "No se pudo cargar el pad: \(error.localizedDescription)"
        }
    }

    private func loadFactoryTones() {
        let notes: [Double] = [261.63, 329.63, 392.00, 523.25, 659.25, 783.99, 1046.50, 1318.51]
        let frames = AVAudioFrameCount(padFormat.sampleRate * 0.6)
        for (i, freq) in notes.enumerated() {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: padFormat, frameCapacity: frames),
                  let data = buffer.floatChannelData else { continue }
            buffer.frameLength = frames
            for n in 0..<Int(frames) {
                let t = Double(n) / padFormat.sampleRate
                let env = exp(-t * 6) * min(1, t / 0.005)
                let v = Float(0.4 * env * (sin(2 * .pi * freq * t) + 0.3 * sin(4 * .pi * freq * t)))
                data[0][n] = v
                data[1][n] = v
            }
            padBuffers[i] = buffer
        }
    }
}
