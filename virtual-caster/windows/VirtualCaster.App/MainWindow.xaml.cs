using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using VirtualCaster.Core;

namespace VirtualCaster.App;

public sealed record DeviceItem(string? Id, string Name);

public partial class MainWindow : Window
{
    private readonly AudioHost _host = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Button[] _pads = new Button[SoundPad.PadCount];
    private bool _ready;

    public MainWindow()
    {
        InitializeComponent();
        LoadDevices();
        BuildPads();
        _host.Engine.Pads.LoadFactoryTones(_host.Engine.SampleRate);
        _timer.Tick += (_, _) => UpdateMeters();
        _timer.Start();
        _ready = true;
        PushParams();
    }

    private void LoadDevices()
    {
        var none = new DeviceItem(null, "(ninguno)");
        using var en = new MMDeviceEnumerator();
        var captures = en.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Select(d => new DeviceItem(d.ID, d.FriendlyName)).ToList();
        var renders = en.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .Select(d => new DeviceItem(d.ID, d.FriendlyName)).ToList();

        foreach (var cb in new[] { cbMic1, cbMic2, cbMusic })
        {
            cb.ItemsSource = captures.Prepend(none).ToList();
            cb.SelectedIndex = 0;
        }
        if (captures.Count > 0) cbMic1.SelectedIndex = 1;

        foreach (var cb in new[] { cbLoop, cbStream })
        {
            cb.ItemsSource = renders.Prepend(none).ToList();
            cb.SelectedIndex = 0;
        }
        cbPhones.ItemsSource = renders;
        if (renders.Count > 0) cbPhones.SelectedIndex = 0;

        foreach (var cb in new[] { cbMic1Ch, cbMic2Ch })
        {
            cb.ItemsSource = new[] { "Todos", "1", "2", "3", "4" };
            cb.SelectedIndex = 0;
        }
    }

    private void BuildPads()
    {
        for (int i = 0; i < _pads.Length; i++)
        {
            int pad = i;
            var b = new Button { Content = $"PAD {i + 1}", Margin = new Thickness(6), FontWeight = FontWeights.SemiBold };
            b.Click += (_, _) => _host.Engine.Pads.Toggle(pad);
            b.MouseRightButtonUp += (_, e) => { LoadPad(pad); e.Handled = true; };
            _pads[i] = b;
            padGrid.Children.Add(b);
        }
    }

    private void LoadPad(int pad)
    {
        var dlg = new OpenFileDialog { Filter = "Audio|*.wav;*.mp3;*.m4a;*.aac;*.wma|Todos los archivos|*.*" };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            _host.Engine.Pads.Load(pad, AudioHost.LoadClip(dlg.FileName));
            _pads[pad].Content = System.IO.Path.GetFileNameWithoutExtension(dlg.FileName);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "No se pudo cargar el archivo", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnParam(object sender, RoutedEventArgs e) => PushParams();

    private void PushParams()
    {
        if (!_ready) return;
        var m = _host.Engine;
        m.Mic1.GainDb = (float)slGain1.Value; m.Mic2.GainDb = (float)slGain2.Value;
        m.Mic1.Fader = (float)slFader1.Value; m.Mic2.Fader = (float)slFader2.Value;
        m.Mic1.Muted = tgMute1.IsChecked == true; m.Mic2.Muted = tgMute2.IsChecked == true;
        m.EqLowDb = (float)slLow.Value; m.EqMidDb = (float)slMid.Value; m.EqHighDb = (float)slHigh.Value;
        m.MusicLevel = (float)slMusic.Value; m.OutputLevel = (float)slOutput.Value;
        m.HeadphoneLevel = (float)slPhones.Value; m.PadLevel = (float)slPadVol.Value;
        m.ReverbAmount = (float)slReverb.Value;
        m.Monitor = tgMonitor.IsChecked == true;
        m.DryRecording = tgDry.IsChecked == true;
        m.SideChain = tgSide.IsChecked == true;
        m.Loopback = tgLoop.IsChecked == true;
    }

    private void OnPreset(object sender, RoutedEventArgs e)
    {
        var values = Enum.GetValues<ReverbPreset>();
        var next = values[(Array.IndexOf(values, _host.Engine.ReverbPreset) + 1) % values.Length];
        _host.Engine.ReverbPreset = next;
        btnPreset.Content = $"REVERB: {next}";
    }

    private void OnSing(object sender, RoutedEventArgs e)
    {
        var m = _host.Engine;
        m.SingAlong = (SingAlongMode)(((int)m.SingAlong + 1) % 3);
        btnSing.Content = m.SingAlong switch
        {
            SingAlongMode.SingAlong => "SING ALONG",
            SingAlongMode.MusicOnly => "MUSIC ONLY",
            _ => "SING ALONG: off",
        };
    }

    private void OnNoise(object sender, RoutedEventArgs e)
    {
        var m = _host.Engine;
        m.NoiseReducer = (NoiseReduction)(((int)m.NoiseReducer + 1) % 3);
        btnNoise.Content = m.NoiseReducer switch
        {
            NoiseReduction.Low => "NOISE RED.: bajo",
            NoiseReduction.High => "NOISE RED.: alto",
            _ => "NOISE RED.: off",
        };
    }

    private void OnStartStop(object sender, RoutedEventArgs e)
    {
        if (_host.Running)
        {
            _host.Stop();
            btnStart.Content = "▶ Encender";
            txtStatus.Text = "Apagada";
            return;
        }
        if (cbPhones.SelectedItem is not DeviceItem { Id: not null } phones)
        {
            txtStatus.Text = "Selecciona un dispositivo de audífonos.";
            return;
        }
        try
        {
            _host.Start(new HostConfig(
                Id(cbMic1), cbMic1Ch.SelectedIndex - 1,
                Id(cbMic2), cbMic2Ch.SelectedIndex - 1,
                Id(cbMusic), Id(cbLoop), phones.Id, Id(cbStream)));
            btnStart.Content = "■ Apagar";
            txtStatus.Text = "Encendida · 48 kHz";
        }
        catch (Exception ex)
        {
            txtStatus.Text = "Error: " + ex.Message;
        }
    }

    private static string? Id(ComboBox cb) => (cb.SelectedItem as DeviceItem)?.Id;

    private void UpdateMeters()
    {
        var m = _host.Engine;
        mMusic.Value = m.MusicMeter.PeakDb; m1.Value = m.Mic1.Meter.PeakDb; m2.Value = m.Mic2.Meter.PeakDb;
        mPad.Value = m.PadMeter.PeakDb; mPhones.Value = m.PhonesMeter.PeakDb; mOut.Value = m.OutputMeter.PeakDb;
        for (int i = 0; i < _pads.Length; i++)
            _pads[i].Opacity = m.Pads.IsPlaying(i) ? 1.0 : 0.75;
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _timer.Stop();
        _host.Dispose();
    }
}
