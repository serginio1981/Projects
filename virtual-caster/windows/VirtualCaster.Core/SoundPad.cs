namespace VirtualCaster.Core;

/// <summary>Banco de 8 pads. Cada pad reproduce un clip estéreo entrelazado a la frecuencia del motor.</summary>
public sealed class SoundPad
{
    public const int PadCount = 8;

    private sealed class Slot
    {
        public volatile float[]? Clip;
        public volatile int Position = -1; // -1 = detenido; índice de muestra (no de trama)
    }

    private readonly Slot[] _slots = Enumerable.Range(0, PadCount).Select(_ => new Slot()).ToArray();

    /// <summary>Carga un clip estéreo entrelazado (L,R,L,R...).</summary>
    public void Load(int pad, float[] stereoInterleaved)
    {
        if (stereoInterleaved.Length % 2 != 0) throw new ArgumentException("El clip debe ser estéreo entrelazado.");
        _slots[pad].Position = -1;
        _slots[pad].Clip = stereoInterleaved;
    }

    public bool IsLoaded(int pad) => _slots[pad].Clip != null;
    public bool IsPlaying(int pad) => _slots[pad].Position >= 0;

    /// <summary>Dispara el pad desde el inicio; si ya estaba sonando, lo detiene.</summary>
    public void Toggle(int pad)
    {
        var s = _slots[pad];
        if (s.Clip == null) return;
        s.Position = s.Position >= 0 ? -1 : 0;
    }

    public void StopAll() { foreach (var s in _slots) s.Position = -1; }

    public void Next(out float left, out float right)
    {
        left = right = 0;
        foreach (var s in _slots)
        {
            int p = s.Position;
            var clip = s.Clip;
            if (p < 0 || clip == null) continue;
            if (p + 1 >= clip.Length) { s.Position = -1; continue; }
            left += clip[p]; right += clip[p + 1];
            s.Position = p + 2;
        }
    }

    /// <summary>Sonidos sintéticos de fábrica para que los pads funcionen sin cargar archivos.</summary>
    public void LoadFactoryTones(int sampleRate)
    {
        double[] notes = { 261.63, 329.63, 392.00, 523.25, 659.25, 783.99, 1046.50, 1318.51 };
        for (int i = 0; i < PadCount; i++)
        {
            int frames = sampleRate * 6 / 10;
            var clip = new float[frames * 2];
            for (int n = 0; n < frames; n++)
            {
                double t = (double)n / sampleRate;
                double env = Math.Exp(-t * 6) * Math.Min(1, t / 0.005);
                float v = (float)(0.4 * env * (Math.Sin(2 * Math.PI * notes[i] * t) + 0.3 * Math.Sin(4 * Math.PI * notes[i] * t)));
                clip[2 * n] = clip[2 * n + 1] = v;
            }
            Load(i, clip);
        }
    }
}
