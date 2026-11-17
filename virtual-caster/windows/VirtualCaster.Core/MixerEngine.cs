namespace VirtualCaster.Core;

/// <summary>Canal de micrófono: ganancia → puerta de ruido → EQ → fader → mute.</summary>
public sealed class ChannelStrip
{
    private readonly NoiseGate _gate;
    private readonly ThreeBandEq _eq;
    private Smoothed _level;

    public ChannelStrip(int sampleRate)
    {
        _gate = new NoiseGate(sampleRate);
        _eq = new ThreeBandEq(sampleRate);
        _level = new Smoothed(1f, sampleRate);
        Meter = new PeakMeter(sampleRate);
    }

    /// <summary>Perilla GAIN, en dB (−20 a +20).</summary>
    public float GainDb { get; set; }
    /// <summary>Fader, 0 a 1 (curva cuadrática; 1 = ganancia unitaria).</summary>
    public float Fader { get; set; } = 0.8f;
    public bool Muted { get; set; }
    public PeakMeter Meter { get; }

    internal float Process(float x, bool gate, float lowDb, float midDb, float highDb)
    {
        _eq.SetGains(lowDb, midDb, highDb);
        _level.Target = Muted ? 0f : Db.ToLinear(Math.Clamp(GainDb, -20f, 20f)) * Fader * Fader;
        if (gate) x = _gate.Process(x);
        float y = _eq.Process(x) * _level.Next();
        Meter.Feed(y);
        return y;
    }
}

/// <summary>
/// Motor de mezcla independiente de la plataforma. Recibe bloques ya convertidos a float a la
/// frecuencia del motor y produce dos mezclas estéreo: la de transmisión (STREAM OUT / USB) y la de audífonos.
/// Los parámetros pueden modificarse desde el hilo de la interfaz mientras el hilo de audio llama a Process.
/// </summary>
public sealed class MixerEngine
{
    private readonly Reverb _reverb;
    private readonly Ducker _ducker;
    private Smoothed _music, _pad, _output, _phones, _reverbAmt;

    public MixerEngine(int sampleRate = 48000)
    {
        SampleRate = sampleRate;
        Mic1 = new ChannelStrip(sampleRate);
        Mic2 = new ChannelStrip(sampleRate);
        _reverb = new Reverb(sampleRate);
        _ducker = new Ducker(sampleRate);
        Pads = new SoundPad();
        _music = new Smoothed(0.7f, sampleRate);
        _pad = new Smoothed(0.7f, sampleRate);
        _output = new Smoothed(0.8f, sampleRate);
        _phones = new Smoothed(0.7f, sampleRate);
        _reverbAmt = new Smoothed(0.3f, sampleRate);
        MusicMeter = new PeakMeter(sampleRate);
        PadMeter = new PeakMeter(sampleRate);
        PhonesMeter = new PeakMeter(sampleRate);
        OutputMeter = new PeakMeter(sampleRate);
    }

    public int SampleRate { get; }
    public ChannelStrip Mic1 { get; }
    public ChannelStrip Mic2 { get; }
    public SoundPad Pads { get; }

    // Perillas (0..1 salvo EQ en dB)
    public float MusicLevel { get; set; } = 0.7f;
    public float OutputLevel { get; set; } = 0.8f;
    public float HeadphoneLevel { get; set; } = 0.7f;
    public float PadLevel { get; set; } = 0.7f;
    public float ReverbAmount { get; set; } = 0.3f;
    public float EqLowDb { get; set; }
    public float EqMidDb { get; set; }
    public float EqHighDb { get; set; }

    // Botones
    /// <summary>MONITOR: escuchar los micrófonos en los audífonos.</summary>
    public bool Monitor { get; set; }
    /// <summary>DRY/WET: activa (wet) o desactiva (dry) la reverberación de los micrófonos.</summary>
    public bool ReverbEnabled { get; set; }
    public ReverbPreset ReverbPreset { get => _reverb.Preset; set => _reverb.Preset = value; }
    /// <summary>SIDE CHAIN: atenúa la música mientras se habla.</summary>
    public bool SideChain { get; set; }
    /// <summary>SING ALONG: cancela el centro estéreo de la música (atenúa la voz principal).</summary>
    public bool SingAlong { get; set; }
    /// <summary>LOOP BACK: incluye el audio del sistema en la mezcla de transmisión.</summary>
    public bool Loopback { get; set; }
    public bool NoiseReducer { get; set; }

    public PeakMeter MusicMeter { get; }
    public PeakMeter PadMeter { get; }
    public PeakMeter PhonesMeter { get; }
    public PeakMeter OutputMeter { get; }

    /// <param name="mic1">Mono, <paramref name="frames"/> muestras.</param>
    /// <param name="mic2">Mono, <paramref name="frames"/> muestras.</param>
    /// <param name="music">Estéreo entrelazado, 2×frames (AUX / música).</param>
    /// <param name="system">Estéreo entrelazado, 2×frames (audio del sistema para LOOP BACK).</param>
    /// <param name="streamOut">Estéreo entrelazado, 2×frames.</param>
    /// <param name="phonesOut">Estéreo entrelazado, 2×frames.</param>
    public void Process(ReadOnlySpan<float> mic1, ReadOnlySpan<float> mic2, ReadOnlySpan<float> music,
        ReadOnlySpan<float> system, Span<float> streamOut, Span<float> phonesOut, int frames)
    {
        _music.Target = Math.Clamp(MusicLevel, 0, 1);
        _pad.Target = Math.Clamp(PadLevel, 0, 1);
        _output.Target = Math.Clamp(OutputLevel, 0, 1);
        _phones.Target = Math.Clamp(HeadphoneLevel, 0, 1);
        _reverbAmt.Target = ReverbEnabled ? Math.Clamp(ReverbAmount, 0, 1) : 0f;
        bool gate = NoiseReducer, duck = SideChain, sing = SingAlong, loop = Loopback, mon = Monitor;
        float lo = EqLowDb, mi = EqMidDb, hi = EqHighDb;

        for (int i = 0; i < frames; i++)
        {
            float mics = Mic1.Process(mic1[i], gate, lo, mi, hi) + Mic2.Process(mic2[i], gate, lo, mi, hi);

            _reverb.Process(mics, out float wetL, out float wetR);
            float rv = _reverbAmt.Next();
            float voiceL = mics + wetL * rv, voiceR = mics + wetR * rv;

            float mL = music[2 * i], mR = music[2 * i + 1];
            if (sing) mL = mR = (mL - mR) * 0.5f;
            float duckGain = _ducker.Process(mics);
            float mg = _music.Next() * (duck ? duckGain : 1f);
            mL *= mg; mR *= mg;
            MusicMeter.Feed(MathF.Max(MathF.Abs(mL), MathF.Abs(mR)));

            Pads.Next(out float pL, out float pR);
            float pg = _pad.Next();
            pL *= pg; pR *= pg;
            PadMeter.Feed(MathF.Max(MathF.Abs(pL), MathF.Abs(pR)));

            float og = _output.Next(), hg = _phones.Next();
            float sL = voiceL + mL + pL, sR = voiceR + mR + pR;
            if (loop) { sL += system[2 * i]; sR += system[2 * i + 1]; }
            sL = Limiter.Soft(sL * og); sR = Limiter.Soft(sR * og);
            streamOut[2 * i] = sL; streamOut[2 * i + 1] = sR;
            OutputMeter.Feed(MathF.Max(MathF.Abs(sL), MathF.Abs(sR)));

            float hL = mL + pL, hR = mR + pR;
            if (mon) { hL += voiceL; hR += voiceR; }
            hL = Limiter.Soft(hL * hg); hR = Limiter.Soft(hR * hg);
            phonesOut[2 * i] = hL; phonesOut[2 * i + 1] = hR;
            PhonesMeter.Feed(MathF.Max(MathF.Abs(hL), MathF.Abs(hR)));
        }
    }
}
