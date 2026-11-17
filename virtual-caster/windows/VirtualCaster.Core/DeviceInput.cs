namespace VirtualCaster.Core;

/// <summary>
/// Adapta el audio crudo de un dispositivo de captura (cualquier formato PCM/float, frecuencia y nº de canales)
/// a float entrelazado a la frecuencia del motor, y lo guarda en un búfer circular seguro entre hilos.
/// El remuestreo es por interpolación lineal: suficiente para un prototipo, no es calidad de estudio.
/// </summary>
public sealed class DeviceInput
{
    private readonly object _lock = new();
    private readonly bool _isFloat;
    private readonly int _bytesPerSample, _maxLatencySamples;
    private readonly double _step; // tramas de origen por trama de destino
    private readonly float[] _ring;
    private readonly float[] _prev, _cur;
    private int _read, _count;
    private double _phase; // posición fraccionaria entre _prev (0) y _cur (1)
    private bool _primed;

    public int Channels { get; }

    public DeviceInput(int sourceRate, int channels, int bitsPerSample, bool isFloat, int engineRate = 48000)
    {
        if (bitsPerSample is not (16 or 24 or 32)) throw new NotSupportedException($"{bitsPerSample} bits no soportado.");
        if (isFloat && bitsPerSample != 32) throw new NotSupportedException("Solo float de 32 bits.");
        Channels = channels;
        _isFloat = isFloat;
        _bytesPerSample = bitsPerSample / 8;
        _step = (double)sourceRate / engineRate;
        _ring = new float[engineRate / 2 * channels];          // 500 ms de capacidad
        _maxLatencySamples = engineRate * 80 / 1000 * channels; // se descarta lo que supere 80 ms de retraso
        _prev = new float[channels];
        _cur = new float[channels];
    }

    /// <summary>Llamado desde el hilo de captura con los bytes entregados por el dispositivo.</summary>
    public void Write(ReadOnlySpan<byte> data)
    {
        int frameBytes = _bytesPerSample * Channels;
        int frames = data.Length / frameBytes;
        lock (_lock)
        {
            for (int f = 0; f < frames; f++)
            {
                var frame = data.Slice(f * frameBytes, frameBytes);
                Array.Copy(_cur, _prev, Channels);
                for (int c = 0; c < Channels; c++) _cur[c] = Decode(frame.Slice(c * _bytesPerSample, _bytesPerSample));
                if (!_primed) { _primed = true; continue; } // la primera trama solo inicializa el interpolador
                while (_phase < 1.0)
                {
                    float t = (float)_phase;
                    for (int c = 0; c < Channels; c++) Push(_prev[c] + (_cur[c] - _prev[c]) * t);
                    _phase += _step;
                }
                _phase -= 1.0;
            }
        }
    }

    private float Decode(ReadOnlySpan<byte> s) => _bytesPerSample switch
    {
        2 => BitConverter.ToInt16(s) / 32768f,
        3 => ((s[0] | (s[1] << 8) | ((sbyte)s[2] << 16))) / 8388608f,
        _ => _isFloat ? BitConverter.ToSingle(s) : BitConverter.ToInt32(s) / 2147483648f,
    };

    private void Push(float v)
    {
        if (_count == _ring.Length) { _read = (_read + 1) % _ring.Length; _count--; }
        _ring[(_read + _count) % _ring.Length] = v;
        _count++;
    }

    /// <summary>Lee <paramref name="frames"/> tramas entrelazadas; rellena con silencio si no hay suficientes.</summary>
    public void Read(Span<float> dest, int frames)
    {
        int want = frames * Channels;
        lock (_lock)
        {
            int excess = _count - want - _maxLatencySamples;
            if (excess > 0)
            {
                excess -= excess % Channels;
                _read = (_read + excess) % _ring.Length; _count -= excess;
            }
            int n = Math.Min(want, _count);
            for (int i = 0; i < n; i++) dest[i] = _ring[(_read + i) % _ring.Length];
            _read = (_read + n) % _ring.Length; _count -= n;
            dest.Slice(n, want - n).Clear();
        }
    }

    /// <summary>Extrae un canal como mono. channel = −1 mezcla todos los canales.</summary>
    public static void ToMono(ReadOnlySpan<float> interleaved, int channels, int channel, Span<float> mono, int frames)
    {
        for (int i = 0; i < frames; i++)
        {
            if (channel >= 0 && channel < channels) mono[i] = interleaved[i * channels + channel];
            else
            {
                float s = 0;
                for (int c = 0; c < channels; c++) s += interleaved[i * channels + c];
                mono[i] = s / channels;
            }
        }
    }

    /// <summary>Convierte a estéreo: mono se duplica; con 2 o más canales se usan los dos primeros.</summary>
    public static void ToStereo(ReadOnlySpan<float> interleaved, int channels, Span<float> stereo, int frames)
    {
        for (int i = 0; i < frames; i++)
        {
            stereo[2 * i] = interleaved[i * channels];
            stereo[2 * i + 1] = interleaved[i * channels + (channels > 1 ? 1 : 0)];
        }
    }
}
