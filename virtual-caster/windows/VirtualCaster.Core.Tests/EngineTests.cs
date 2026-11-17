using VirtualCaster.Core;
using Xunit;

namespace VirtualCaster.Core.Tests;

public class EngineTests
{
    private const int Fs = 48000;

    private static float[] Sine(double freq, int frames, float amp = 0.25f, int fs = Fs)
        => Enumerable.Range(0, frames).Select(n => amp * (float)Math.Sin(2 * Math.PI * freq * n / fs)).ToArray();

    private static float Rms(ReadOnlySpan<float> x)
    {
        double s = 0;
        foreach (var v in x) s += v * v;
        return (float)Math.Sqrt(s / x.Length);
    }

    private static float[] Stereo(float[] mono) => mono.SelectMany(v => new[] { v, v }).ToArray();

    /// <summary>Procesa 1 s y devuelve (stream, audífonos) de la segunda mitad, ya estabilizada.</summary>
    private static (float[] stream, float[] phones) Run(MixerEngine e, float[]? mic1 = null, float[]? music = null, float[]? system = null)
    {
        int n = Fs;
        var zeroMono = new float[n]; var zeroSt = new float[2 * n];
        var s = new float[2 * n]; var p = new float[2 * n];
        e.Process(mic1 ?? zeroMono, zeroMono, music ?? zeroSt, system ?? zeroSt, s, p, n);
        return (s[n..], p[n..]);
    }

    private static MixerEngine Flat() => new(Fs)
    {
        OutputLevel = 1, HeadphoneLevel = 1, MusicLevel = 1, Mic1 = { Fader = 1 }, Mic2 = { Fader = 1 },
    };

    [Fact]
    public void Silencio_entra_silencio_sale()
    {
        var (s, p) = Run(Flat());
        Assert.Equal(0, Rms(s));
        Assert.Equal(0, Rms(p));
    }

    [Fact]
    public void Microfono_plano_pasa_con_ganancia_unitaria()
    {
        var mic = Sine(1000, Fs);
        var (s, _) = Run(Flat(), mic);
        Assert.InRange(Rms(s) / Rms(mic), 0.98f, 1.02f);
    }

    [Fact]
    public void Mute_silencia_el_microfono()
    {
        var e = Flat(); e.Mic1.Muted = true;
        var (s, _) = Run(e, Sine(1000, Fs));
        Assert.True(Rms(s) < 1e-4f);
    }

    [Fact]
    public void Monitor_controla_microfono_en_audifonos()
    {
        var mic = Sine(1000, Fs);
        var (_, off) = Run(Flat(), mic);
        var on = Flat(); on.Monitor = true;
        var (_, p) = Run(on, mic);
        Assert.True(Rms(off) < 1e-4f);
        Assert.InRange(Rms(p) / Rms(mic), 0.98f, 1.02f);
    }

    [Theory]
    [InlineData(80, 10f, 0f, 0f)]
    [InlineData(1500, 0f, 10f, 0f)]
    [InlineData(14000, 0f, 0f, 10f)]
    public void Eq_realza_su_banda(double freq, float lo, float mi, float hi)
    {
        var mic = Sine(freq, Fs, 0.05f);
        var e = Flat(); e.EqLowDb = lo; e.EqMidDb = mi; e.EqHighDb = hi;
        var (s, _) = Run(e, mic);
        float gainDb = Db.FromLinear(Rms(s) / Rms(mic));
        Assert.InRange(gainDb, 7f, 10.5f);
    }

    [Fact]
    public void Eq_low_no_afecta_agudos()
    {
        var mic = Sine(8000, Fs, 0.05f);
        var e = Flat(); e.EqLowDb = 10;
        var (s, _) = Run(e, mic);
        Assert.InRange(Db.FromLinear(Rms(s) / Rms(mic)), -0.5f, 0.5f);
    }

    [Fact]
    public void Reverb_agrega_energia_y_cola()
    {
        var e = Flat(); e.ReverbEnabled = true; e.ReverbAmount = 1; e.ReverbPreset = ReverbPreset.Catedral;
        int n = Fs;
        var mic = new float[n];
        Array.Copy(Sine(440, Fs / 10), mic, Fs / 10); // 100 ms de tono y luego silencio
        var s = new float[2 * n]; var p = new float[2 * n];
        e.Process(mic, new float[n], new float[2 * n], new float[2 * n], s, p, n);
        Assert.True(Rms(s.AsSpan(2 * (Fs / 2))) > 1e-4f, "debe quedar cola de reverberación tras el tono");
        Assert.All(s, v => Assert.True(float.IsFinite(v) && MathF.Abs(v) <= 1f));
    }

    [Fact]
    public void SideChain_atenua_la_musica_al_hablar()
    {
        var music = Stereo(Sine(300, Fs));
        var mic = Sine(1000, Fs);
        var muted = Flat(); muted.SideChain = true;
        var (sinVoz, _) = Run(muted, null, music);
        var e = Flat(); e.SideChain = true; e.Mic1.Fader = 1;
        var (_, phones) = Run(e, mic, music); // audífonos sin monitor = solo música
        float reduccionDb = Db.FromLinear(Rms(phones) / Rms(sinVoz));
        Assert.InRange(reduccionDb, -15f, -12f);
    }

    [Fact]
    public void SingAlong_cancela_el_centro()
    {
        var e = Flat(); e.SingAlong = true;
        var (s, _) = Run(e, null, Stereo(Sine(500, Fs)));
        Assert.True(Rms(s) < 1e-4f);
    }

    [Fact]
    public void Loopback_solo_va_a_transmision()
    {
        var sys = Stereo(Sine(700, Fs));
        var (off, _) = Run(Flat(), null, null, sys);
        var e = Flat(); e.Loopback = true;
        var (on, phones) = Run(e, null, null, sys);
        Assert.True(Rms(off) < 1e-4f);
        Assert.True(Rms(on) > 0.1f);
        Assert.True(Rms(phones) < 1e-4f);
    }

    [Fact]
    public void NoiseReducer_atenua_ruido_bajo_y_respeta_voz()
    {
        var e = Flat(); e.NoiseReducer = true;
        var ruido = Sine(1000, Fs, 0.001f); // −60 dBFS
        var (s, _) = Run(e, ruido);
        Assert.True(Db.FromLinear(Rms(s) / Rms(ruido)) < -25f);
        var e2 = Flat(); e2.NoiseReducer = true;
        var voz = Sine(1000, Fs, 0.25f);
        var (s2, _) = Run(e2, voz);
        Assert.InRange(Rms(s2) / Rms(voz), 0.97f, 1.02f);
    }

    [Fact]
    public void Pads_suenan_y_terminan()
    {
        var e = Flat(); e.PadLevel = 1;
        e.Pads.LoadFactoryTones(Fs);
        e.Pads.Toggle(0);
        Assert.True(e.Pads.IsPlaying(0));
        int n = Fs;
        var s = new float[2 * n]; var p = new float[2 * n];
        e.Process(new float[n], new float[n], new float[2 * n], new float[2 * n], s, p, n);
        Assert.True(Rms(s.AsSpan(0, Fs / 2)) > 0.01f);
        Assert.False(e.Pads.IsPlaying(0)); // el clip dura 0,6 s
    }

    [Fact]
    public void Limitador_nunca_supera_escala_completa()
    {
        var e = Flat(); e.Mic1.GainDb = 20;
        var (s, _) = Run(e, Sine(1000, Fs, 0.9f));
        Assert.All(s, v => Assert.True(MathF.Abs(v) <= 1f));
    }
}

public class DeviceInputTests
{
    private static byte[] Pcm16(float[] x)
    {
        var b = new byte[x.Length * 2];
        for (int i = 0; i < x.Length; i++) BitConverter.TryWriteBytes(b.AsSpan(2 * i), (short)(x[i] * 32767));
        return b;
    }

    [Fact]
    public void Decodifica_pcm16_sin_remuestreo()
    {
        var d = new DeviceInput(48000, 1, 16, false);
        var src = new[] { 0f, 0.5f, -0.5f, 0.25f, 0f }; // el interpolador retiene la última trama
        d.Write(Pcm16(src));
        var o = new float[4];
        d.Read(o, 4);
        for (int i = 0; i < 4; i++) Assert.Equal((double)src[i], o[i], 3);
    }

    [Fact]
    public void Decodifica_pcm24_con_signo()
    {
        var d = new DeviceInput(48000, 1, 24, false);
        d.Write(new byte[] { 0x00, 0x00, 0xC0, 0x00, 0x00, 0x40, 0, 0, 0 }); // −0,5, +0,5 y una trama final retenida
        var o = new float[2];
        d.Read(o, 2);
        Assert.Equal(-0.5, o[0], 4);
        Assert.Equal(0.5, o[1], 4);
    }

    [Fact]
    public void Remuestrea_44100_a_48000_conservando_frecuencia_y_duracion()
    {
        var d = new DeviceInput(44100, 1, 16, false);
        var src = Enumerable.Range(0, 44100).Select(n => 0.5f * (float)Math.Sin(2 * Math.PI * 1000 * n / 44100.0)).ToArray();
        var bytes = Pcm16(src);
        var o = new float[48000];
        int got = 0;
        for (int off = 0; off < bytes.Length; off += 882) // paquetes de 10 ms, lectura intercalada como en tiempo real
        {
            d.Write(bytes.AsSpan(off, Math.Min(882, bytes.Length - off)));
            int n = Math.Min(480, o.Length - got);
            d.Read(o.AsSpan(got), n);
            got += n;
        }
        int cruces = 0;
        for (int i = 1; i < got; i++) if (o[i - 1] < 0 && o[i] >= 0) cruces++;
        Assert.InRange(cruces, 995, 1001); // ≈1000 ciclos en ≈1 s
    }

    [Fact]
    public void Falta_de_datos_rellena_con_silencio()
    {
        var d = new DeviceInput(48000, 2, 32, true);
        var o = new float[] { 9, 9, 9, 9 };
        d.Read(o, 2);
        Assert.All(o, v => Assert.Equal(0f, v));
    }

    [Fact]
    public void Seleccion_de_canal()
    {
        var inter = new float[] { 1, 2, 3, 4 };
        var m = new float[2];
        DeviceInput.ToMono(inter, 2, 1, m, 2);
        Assert.Equal(new float[] { 2, 4 }, m);
        DeviceInput.ToMono(inter, 2, -1, m, 2);
        Assert.Equal(new float[] { 1.5f, 3.5f }, m);
    }
}
