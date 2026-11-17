using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using VirtualCaster.Core;

namespace VirtualCaster.App;

/// <summary>Selección de dispositivos. Canal −1 = mezcla de todos los canales del dispositivo.</summary>
public sealed record HostConfig(
    string? Mic1Id, int Mic1Channel,
    string? Mic2Id, int Mic2Channel,
    string? MusicId,
    string? LoopbackId,
    string PhonesId,
    string? StreamId);

/// <summary>
/// Conecta el motor de mezcla con WASAPI. El dispositivo de audífonos es el reloj maestro: cada vez que pide
/// audio se leen las entradas, se procesa un bloque y la mezcla de transmisión se encola hacia el segundo
/// dispositivo (p. ej. la entrada de un cable virtual como VB-CABLE).
/// </summary>
public sealed class AudioHost : IDisposable
{
    private const int Rate = 48000;
    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00aa00389b71");

    private readonly List<IWaveIn> _captures = new();
    private readonly Dictionary<string, DeviceInput> _inputs = new();
    private WasapiOut? _phones, _stream;

    public MixerEngine Engine { get; } = new(Rate);
    public bool Running { get; private set; }

    public void Start(HostConfig c)
    {
        if (Running) return;
        if (c.LoopbackId != null && (c.LoopbackId == c.PhonesId || c.LoopbackId == c.StreamId))
            throw new InvalidOperationException(
                "El dispositivo de LOOP BACK no puede ser el mismo que el de audífonos o el de transmisión: " +
                "se capturaría la propia salida de la consola y se produciría eco o realimentación.");
        if (c.StreamId == c.PhonesId)
            throw new InvalidOperationException("Audífonos y transmisión deben ser dispositivos distintos.");

        try
        {
            using var en = new MMDeviceEnumerator();
            var provider = new MixerProvider(Engine)
            {
                Mic1 = Open(en, c.Mic1Id, false), Mic1Channel = c.Mic1Channel,
                Mic2 = Open(en, c.Mic2Id, false), Mic2Channel = c.Mic2Channel,
                Music = Open(en, c.MusicId, false),
                SystemAudio = Open(en, c.LoopbackId, true),
            };

            if (c.StreamId != null)
            {
                provider.StreamBuffer = new BufferedWaveProvider(provider.WaveFormat)
                {
                    BufferDuration = TimeSpan.FromMilliseconds(200),
                    DiscardOnBufferOverflow = true,
                    ReadFully = true,
                };
                _stream = new WasapiOut(en.GetDevice(c.StreamId), AudioClientShareMode.Shared, true, 20);
                _stream.Init(provider.StreamBuffer);
            }

            _phones = new WasapiOut(en.GetDevice(c.PhonesId), AudioClientShareMode.Shared, true, 20);
            _phones.Init(provider);

            foreach (var cap in _captures) cap.StartRecording();
            _stream?.Play();
            _phones.Play();
            Running = true;
        }
        catch
        {
            Stop();
            throw;
        }
    }

    private DeviceInput? Open(MMDeviceEnumerator en, string? id, bool loopback)
    {
        if (id == null) return null;
        string key = (loopback ? "L:" : "C:") + id;
        if (_inputs.TryGetValue(key, out var existing)) return existing; // mismo dispositivo para Mic 1 y Mic 2

        var device = en.GetDevice(id);
        IWaveIn cap = loopback ? new WasapiLoopbackCapture(device) : new WasapiCapture(device);
        var f = cap.WaveFormat;
        bool isFloat = f.Encoding == WaveFormatEncoding.IeeeFloat ||
                       (f is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubFormat);
        var input = new DeviceInput(f.SampleRate, f.Channels, f.BitsPerSample, isFloat, Rate);
        cap.DataAvailable += (_, e) => input.Write(e.Buffer.AsSpan(0, e.BytesRecorded));
        _captures.Add(cap);
        _inputs[key] = input;
        return input;
    }

    public void Stop()
    {
        _phones?.Stop(); _phones?.Dispose(); _phones = null;
        _stream?.Stop(); _stream?.Dispose(); _stream = null;
        foreach (var cap in _captures)
        {
            try { cap.StopRecording(); } catch (Exception) { /* el dispositivo pudo haberse desconectado */ }
            cap.Dispose();
        }
        _captures.Clear();
        _inputs.Clear();
        Running = false;
    }

    public void Dispose() => Stop();

    /// <summary>Carga un archivo de audio (WAV, MP3, M4A...) como clip estéreo a 48 kHz para un pad. Máximo 60 s.</summary>
    public static float[] LoadClip(string path)
    {
        using var reader = new MediaFoundationReader(path);
        ISampleProvider sp = reader.ToSampleProvider();
        if (sp.WaveFormat.Channels == 1) sp = new MonoToStereoSampleProvider(sp);
        else if (sp.WaveFormat.Channels != 2) throw new NotSupportedException("Solo se admiten archivos mono o estéreo.");
        if (sp.WaveFormat.SampleRate != Rate) sp = new WdlResamplingSampleProvider(sp, Rate);

        var samples = new List<float>();
        var buf = new float[Rate * 2];
        int n;
        while ((n = sp.Read(buf, 0, buf.Length)) > 0 && samples.Count < Rate * 2 * 60)
            samples.AddRange(buf.AsSpan(0, n).ToArray());
        if (samples.Count % 2 != 0) samples.RemoveAt(samples.Count - 1);
        return samples.ToArray();
    }

    private sealed class MixerProvider : ISampleProvider
    {
        private readonly MixerEngine _engine;
        private float[] _raw = Array.Empty<float>(), _mic1 = Array.Empty<float>(), _mic2 = Array.Empty<float>();
        private float[] _music = Array.Empty<float>(), _system = Array.Empty<float>(), _streamMix = Array.Empty<float>();
        private byte[] _bytes = Array.Empty<byte>();

        public MixerProvider(MixerEngine engine) => _engine = engine;

        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(Rate, 2);
        public DeviceInput? Mic1, Mic2, Music, SystemAudio;
        public int Mic1Channel, Mic2Channel;
        public BufferedWaveProvider? StreamBuffer;

        public int Read(float[] buffer, int offset, int count)
        {
            int frames = count / 2;
            if (_mic1.Length < frames)
            {
                _mic1 = new float[frames]; _mic2 = new float[frames];
                _music = new float[frames * 2]; _system = new float[frames * 2]; _streamMix = new float[frames * 2];
                _bytes = new byte[frames * 2 * sizeof(float)];
            }

            if (Mic1 != null && ReferenceEquals(Mic1, Mic2))
            {
                var raw = ReadRaw(Mic1, frames);
                DeviceInput.ToMono(raw, Mic1.Channels, Mic1Channel, _mic1, frames);
                DeviceInput.ToMono(raw, Mic1.Channels, Mic2Channel, _mic2, frames);
            }
            else
            {
                FillMono(Mic1, Mic1Channel, _mic1, frames);
                FillMono(Mic2, Mic2Channel, _mic2, frames);
            }
            FillStereo(Music, _music, frames);
            FillStereo(SystemAudio, _system, frames);

            _engine.Process(_mic1, _mic2, _music, _system, _streamMix, buffer.AsSpan(offset, frames * 2), frames);

            if (StreamBuffer != null)
            {
                Buffer.BlockCopy(_streamMix, 0, _bytes, 0, frames * 2 * sizeof(float));
                StreamBuffer.AddSamples(_bytes, 0, frames * 2 * sizeof(float));
            }
            return frames * 2;
        }

        private Span<float> ReadRaw(DeviceInput input, int frames)
        {
            int need = frames * input.Channels;
            if (_raw.Length < need) _raw = new float[need];
            input.Read(_raw, frames);
            return _raw.AsSpan(0, need);
        }

        private void FillMono(DeviceInput? input, int channel, float[] dest, int frames)
        {
            if (input == null) { Array.Clear(dest, 0, frames); return; }
            DeviceInput.ToMono(ReadRaw(input, frames), input.Channels, channel, dest, frames);
        }

        private void FillStereo(DeviceInput? input, float[] dest, int frames)
        {
            if (input == null) { Array.Clear(dest, 0, frames * 2); return; }
            DeviceInput.ToStereo(ReadRaw(input, frames), input.Channels, dest, frames);
        }
    }
}
