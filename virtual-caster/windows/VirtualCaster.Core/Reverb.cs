namespace VirtualCaster.Core;

public enum ReverbPreset { Sala, Estudio, Hall, Catedral }

/// <summary>
/// Reverberación estilo Freeverb (8 filtros peine + 4 pasa-todo por canal; algoritmo de dominio público de "Jezar").
/// Entrega solo la señal húmeda; la mezcla con la señal seca se hace en el mezclador.
/// </summary>
public sealed class Reverb
{
    private static readonly int[] CombTuning = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
    private static readonly int[] AllpassTuning = { 556, 441, 341, 225 };
    private const int StereoSpread = 23;
    private const float InputGain = 0.015f;

    private readonly Comb[] _combL, _combR;
    private readonly Allpass[] _apL, _apR;
    private ReverbPreset _preset;

    public Reverb(int sampleRate)
    {
        double k = sampleRate / 44100.0;
        _combL = CombTuning.Select(n => new Comb((int)(n * k))).ToArray();
        _combR = CombTuning.Select(n => new Comb((int)((n + StereoSpread) * k))).ToArray();
        _apL = AllpassTuning.Select(n => new Allpass((int)(n * k))).ToArray();
        _apR = AllpassTuning.Select(n => new Allpass((int)((n + StereoSpread) * k))).ToArray();
        _preset = ReverbPreset.Hall;
        Apply();
    }

    public ReverbPreset Preset
    {
        get => _preset;
        set { if (value != _preset) { _preset = value; Apply(); } }
    }

    private void Apply()
    {
        (float room, float damp) = _preset switch
        {
            ReverbPreset.Sala => (0.30f, 0.60f),
            ReverbPreset.Estudio => (0.50f, 0.50f),
            ReverbPreset.Hall => (0.75f, 0.35f),
            _ => (0.92f, 0.20f),
        };
        float feedback = room * 0.28f + 0.7f, d = damp * 0.4f;
        foreach (var c in _combL) { c.Feedback = feedback; c.Damp = d; }
        foreach (var c in _combR) { c.Feedback = feedback; c.Damp = d; }
    }

    public void Process(float input, out float left, out float right)
    {
        float x = input * InputGain, l = 0, r = 0;
        for (int i = 0; i < _combL.Length; i++) { l += _combL[i].Process(x); r += _combR[i].Process(x); }
        for (int i = 0; i < _apL.Length; i++) { l = _apL[i].Process(l); r = _apR[i].Process(r); }
        left = l * 3f; right = r * 3f;
    }

    private sealed class Comb
    {
        private readonly float[] _buf;
        private int _i;
        private float _store;
        public float Feedback, Damp;

        public Comb(int size) => _buf = new float[Math.Max(1, size)];

        public float Process(float x)
        {
            float o = _buf[_i];
            _store = o * (1 - Damp) + _store * Damp;
            _buf[_i] = x + _store * Feedback;
            if (++_i >= _buf.Length) _i = 0;
            return o;
        }
    }

    private sealed class Allpass
    {
        private readonly float[] _buf;
        private int _i;

        public Allpass(int size) => _buf = new float[Math.Max(1, size)];

        public float Process(float x)
        {
            float b = _buf[_i];
            _buf[_i] = x + b * 0.5f;
            if (++_i >= _buf.Length) _i = 0;
            return b - x;
        }
    }
}
