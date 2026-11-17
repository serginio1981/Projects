namespace VirtualCaster.Core;

/// <summary>Utilidades de conversión.</summary>
public static class Db
{
    public static float ToLinear(float db) => MathF.Pow(10f, db / 20f);
    public static float FromLinear(float lin) => lin <= 1e-9f ? -180f : 20f * MathF.Log10(lin);
}

/// <summary>Filtro bicuadrático (fórmulas del "Audio EQ Cookbook" de R. Bristow-Johnson), forma directa II transpuesta.</summary>
public sealed class Biquad
{
    private double _b0 = 1, _b1, _b2, _a1, _a2, _z1, _z2;

    public void SetPeaking(double fs, double f, double q, double gainDb)
    {
        double a = Math.Pow(10, gainDb / 40), w = 2 * Math.PI * f / fs, cs = Math.Cos(w), al = Math.Sin(w) / (2 * q);
        Set(1 + al * a, -2 * cs, 1 - al * a, 1 + al / a, -2 * cs, 1 - al / a);
    }

    public void SetLowShelf(double fs, double f, double q, double gainDb)
    {
        double a = Math.Pow(10, gainDb / 40), w = 2 * Math.PI * f / fs, cs = Math.Cos(w), al = Math.Sin(w) / (2 * q);
        double k = 2 * Math.Sqrt(a) * al;
        Set(a * ((a + 1) - (a - 1) * cs + k), 2 * a * ((a - 1) - (a + 1) * cs), a * ((a + 1) - (a - 1) * cs - k),
            (a + 1) + (a - 1) * cs + k, -2 * ((a - 1) + (a + 1) * cs), (a + 1) + (a - 1) * cs - k);
    }

    public void SetHighShelf(double fs, double f, double q, double gainDb)
    {
        double a = Math.Pow(10, gainDb / 40), w = 2 * Math.PI * f / fs, cs = Math.Cos(w), al = Math.Sin(w) / (2 * q);
        double k = 2 * Math.Sqrt(a) * al;
        Set(a * ((a + 1) + (a - 1) * cs + k), -2 * a * ((a - 1) + (a + 1) * cs), a * ((a + 1) + (a - 1) * cs - k),
            (a + 1) - (a - 1) * cs + k, 2 * ((a - 1) - (a + 1) * cs), (a + 1) - (a - 1) * cs - k);
    }

    private void Set(double b0, double b1, double b2, double a0, double a1, double a2)
    {
        _b0 = b0 / a0; _b1 = b1 / a0; _b2 = b2 / a0; _a1 = a1 / a0; _a2 = a2 / a0;
    }

    public float Process(float x)
    {
        double y = _b0 * x + _z1;
        _z1 = _b1 * x - _a1 * y + _z2;
        _z2 = _b2 * x - _a2 * y;
        return (float)y;
    }
}

/// <summary>EQ de 3 bandas (LOW / MID / HI), ±10 dB como las perillas de la consola.</summary>
public sealed class ThreeBandEq
{
    private readonly int _fs;
    private readonly Biquad _low = new(), _mid = new(), _high = new();
    private float _lowDb, _midDb, _highDb;

    public ThreeBandEq(int sampleRate) { _fs = sampleRate; Update(); }

    public void SetGains(float lowDb, float midDb, float highDb)
    {
        lowDb = Math.Clamp(lowDb, -10f, 10f); midDb = Math.Clamp(midDb, -10f, 10f); highDb = Math.Clamp(highDb, -10f, 10f);
        if (lowDb == _lowDb && midDb == _midDb && highDb == _highDb) return;
        _lowDb = lowDb; _midDb = midDb; _highDb = highDb;
        Update();
    }

    private void Update()
    {
        _low.SetLowShelf(_fs, 120, 0.707, _lowDb);
        _mid.SetPeaking(_fs, 1500, 0.8, _midDb);
        _high.SetHighShelf(_fs, 8000, 0.707, _highDb);
    }

    public float Process(float x) => _high.Process(_mid.Process(_low.Process(x)));
}

/// <summary>
/// Puerta de ruido: atenúa la señal cuando su envolvente cae bajo un umbral.
/// Es una aproximación simple al botón NOISE REDUCER; no es una reducción de ruido espectral.
/// </summary>
public sealed class NoiseGate
{
    private readonly float _attack, _release, _envRelease;
    private readonly int _holdSamples;
    private float _env, _gain = 1f;
    private int _hold;

    public float ThresholdDb { get; set; } = -45f;
    public float FloorDb { get; set; } = -60f;

    public NoiseGate(int sampleRate)
    {
        _attack = Coef(0.002f, sampleRate);
        _release = Coef(0.150f, sampleRate);
        _envRelease = Coef(0.020f, sampleRate);
        _holdSamples = sampleRate / 10;
    }

    internal static float Coef(float seconds, int fs) => 1f - MathF.Exp(-1f / (seconds * fs));

    public float Process(float x)
    {
        float a = MathF.Abs(x);
        _env = a > _env ? a : _env + (a - _env) * _envRelease;
        float target;
        if (_env >= Db.ToLinear(ThresholdDb)) { _hold = _holdSamples; target = 1f; }
        else if (_hold > 0) { _hold--; target = 1f; }
        else target = Db.ToLinear(FloorDb);
        _gain += (target - _gain) * (target > _gain ? _attack : _release);
        return x * _gain;
    }
}

/// <summary>Atenuador por cadena lateral (SIDE CHAIN): baja la música mientras hay voz.</summary>
public sealed class Ducker
{
    private readonly float _attack, _release, _envRelease;
    private float _env, _gain = 1f;

    public float ThresholdDb { get; set; } = -35f;
    public float DuckDb { get; set; } = -14f;

    public Ducker(int sampleRate)
    {
        _attack = NoiseGate.Coef(0.030f, sampleRate);
        _release = NoiseGate.Coef(0.600f, sampleRate);
        _envRelease = NoiseGate.Coef(0.100f, sampleRate);
    }

    /// <summary>Recibe la señal de control (voz) y devuelve la ganancia a aplicar a la música.</summary>
    public float Process(float key)
    {
        float a = MathF.Abs(key);
        _env = a > _env ? a : _env + (a - _env) * _envRelease;
        float target = _env >= Db.ToLinear(ThresholdDb) ? Db.ToLinear(DuckDb) : 1f;
        _gain += (target - _gain) * (target < _gain ? _attack : _release);
        return _gain;
    }
}

/// <summary>Medidor de pico con caída, para las barras de LED.</summary>
public sealed class PeakMeter
{
    private readonly float _decay;
    private float _peak;

    public PeakMeter(int sampleRate) => _decay = MathF.Exp(-1f / (0.3f * sampleRate));

    public void Feed(float x)
    {
        float a = MathF.Abs(x);
        _peak = a > _peak ? a : _peak * _decay;
    }

    public float Peak => _peak;
    public float PeakDb => Db.FromLinear(_peak);
}

/// <summary>Suaviza cambios de parámetro para evitar "zipper noise".</summary>
public struct Smoothed
{
    private float _current;
    private readonly float _coef;
    public float Target;

    public Smoothed(float initial, int sampleRate) { _current = Target = initial; _coef = NoiseGate.Coef(0.010f, sampleRate); }

    public float Next() => _current += (Target - _current) * _coef;
}

public static class Limiter
{
    /// <summary>Limitador suave: lineal hasta 0,8 y compresión asintótica hacia 1,0.</summary>
    public static float Soft(float x)
    {
        float a = MathF.Abs(x);
        if (a <= 0.8f) return x;
        float y = 0.8f + 0.2f * MathF.Tanh((a - 0.8f) / 0.2f);
        return x < 0 ? -y : y;
    }
}
