using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using VirtualCaster.Core;

namespace VirtualCaster.App;

public partial class MainWindow : Window
{
    private static readonly DeviceItem None = new(null, "(ninguno)");

    private readonly AudioHost _host = new();
    private readonly DeviceWatcher _watcher = new();
    private readonly DispatcherTimer _meterTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly DispatcherTimer _deviceTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private readonly Button[] _pads = new Button[SoundPad.PadCount];
    private bool _ready, _firstDeviceLoad = true;

    public MainWindow()
    {
        InitializeComponent();

        foreach (var cb in new[] { cbMic1Ch, cbMic2Ch })
        {
            cb.ItemsSource = new[] { "Todos", "1", "2", "3", "4" };
            cb.SelectedIndex = 0;
        }
        LoadDevices();
        BuildPads();
        _host.Engine.Pads.LoadFactoryTones(_host.Engine.SampleRate);

        _meterTimer.Tick += (_, _) => UpdateMeters();
        _meterTimer.Start();

        // Windows avisa varias veces seguidas y desde otro hilo: se agrupan los avisos y se refresca en el hilo de la interfaz.
        _deviceTimer.Tick += (_, _) => { _deviceTimer.Stop(); LoadDevices(); };
        _watcher.Changed += () => Dispatcher.InvokeAsync(() => { _deviceTimer.Stop(); _deviceTimer.Start(); });

        _ready = true;
        PushParams();

        // Modo de verificación: "VirtualCaster.exe --screenshot ruta.png" dibuja la ventana en un PNG y termina.
        // Lo usa la integración continua para comprobar que la app arranca y para revisar el aspecto.
        var args = Environment.GetCommandLineArgs();
        int shot = Array.IndexOf(args, "--screenshot");
        if (shot >= 0 && shot + 1 < args.Length)
            Loaded += (_, _) => Dispatcher.InvokeAsync(() => SaveScreenshot(args[shot + 1]), DispatcherPriority.ApplicationIdle);
    }

    private void SaveScreenshot(string path)
    {
        try
        {
            var root = (FrameworkElement)Content;
            int w = (int)Math.Ceiling(root.ActualWidth), h = (int)Math.Ceiling(root.ActualHeight);
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(Background, null, new Rect(0, 0, w, h));
                dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, w, h));
            }
            var bitmap = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var file = File.Create(path);
            encoder.Save(file);
        }
        catch (Exception ex)
        {
            File.WriteAllText(path + ".error.txt", ex.ToString());
            Environment.ExitCode = 1;
        }
        Application.Current.Shutdown();
    }

    // ----- Dispositivos -----

    private void LoadDevices()
    {
        DeviceSnapshot snap;
        try { snap = _watcher.Snapshot(); }
        catch (Exception ex) { txtStatus.Text = "No se pudo leer la lista de dispositivos: " + ex.Message; return; }

        var captures = snap.Captures.Prepend(None).ToList();
        var renders = snap.Renders.Prepend(None).ToList();

        // La primera vez se proponen los dispositivos predeterminados de Windows; después se conserva la selección.
        Fill(cbMic1, captures, _firstDeviceLoad ? snap.DefaultCaptureId : null);
        Fill(cbMic2, captures, null);
        Fill(cbMusic, captures, null);
        Fill(cbLoop, renders, null);
        Fill(cbStream, renders, null);
        Fill(cbPhones, snap.Renders, _firstDeviceLoad ? snap.DefaultRenderId : null);
        if (cbPhones.SelectedItem == null && snap.Renders.Count > 0) cbPhones.SelectedIndex = 0;

        if (!_firstDeviceLoad)
            txtStatus.Text = _host.Running
                ? "Encendida · cambió la lista de dispositivos (apaga y enciende para aplicar cambios)"
                : "Apagada · lista de dispositivos actualizada";
        _firstDeviceLoad = false;
    }

    private static void Fill(ComboBox cb, List<DeviceItem> items, string? preferredId)
    {
        string? wanted = (cb.SelectedItem as DeviceItem)?.Id ?? preferredId;
        cb.ItemsSource = items;
        cb.SelectedItem = items.FirstOrDefault(i => i.Id == wanted) ?? items.FirstOrDefault();
    }

    private void OnRefreshDevices(object sender, RoutedEventArgs e) => LoadDevices();

    private static string? Id(ComboBox cb) => (cb.SelectedItem as DeviceItem)?.Id;

    private void OnStartStop(object sender, RoutedEventArgs e)
    {
        if (_host.Running)
        {
            _host.Stop();
            btnStart.Content = "▶ Encender";
            txtStatus.Text = "Apagada";
            return;
        }
        string? phones = Id(cbPhones);
        if (phones == null)
        {
            txtStatus.Text = "Selecciona un dispositivo de audífonos.";
            return;
        }
        try
        {
            _host.Start(new HostConfig(
                Id(cbMic1), cbMic1Ch.SelectedIndex - 1,
                Id(cbMic2), cbMic2Ch.SelectedIndex - 1,
                Id(cbMusic), Id(cbLoop), phones, Id(cbStream)));
            btnStart.Content = "■ Apagar";
            txtStatus.Text = "Encendida · 48 kHz";
        }
        catch (Exception ex)
        {
            txtStatus.Text = "Error: " + ex.Message;
        }
    }

    // ----- Soundpad -----

    private void BuildPads()
    {
        for (int i = 0; i < _pads.Length; i++)
        {
            int pad = i;
            var b = new Button { Content = $"PAD {i + 1}", Style = (Style)FindResource("Pad") };
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
            string name = Path.GetFileNameWithoutExtension(dlg.FileName);
            _pads[pad].Content = name.Length > 16 ? name[..16] + "…" : name;
            _pads[pad].ToolTip = name;
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "No se pudo cargar el archivo", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // ----- Perillas y botones -----

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
        m.SideChain = tgSide.IsChecked == true;
        m.Loopback = tgLoop.IsChecked == true;
    }

    private void OnPreset(object sender, RoutedEventArgs e)
    {
        var values = Enum.GetValues<ReverbPreset>();
        var next = values[(Array.IndexOf(values, _host.Engine.ReverbPreset) + 1) % values.Length];
        _host.Engine.ReverbPreset = next;
        txtPreset.Text = $"REVERB\n{next}";
    }

    private void OnDry(object sender, RoutedEventArgs e)
    {
        bool dry = tgDry.IsChecked == true;
        _host.Engine.DryRecording = dry;
        txtDry.Text = dry ? "DRY/WET\ndry" : "DRY/WET\nwet";
    }

    private void OnSing(object sender, RoutedEventArgs e)
    {
        var m = _host.Engine;
        m.SingAlong = (SingAlongMode)(((int)m.SingAlong + 1) % 3);
        tgSing.IsChecked = m.SingAlong != SingAlongMode.Off;
        txtSing.Text = m.SingAlong == SingAlongMode.MusicOnly ? "MUSIC\nONLY" : "SING\nALONG";
    }

    private void OnNoise(object sender, RoutedEventArgs e)
    {
        var m = _host.Engine;
        m.NoiseReducer = (NoiseReduction)(((int)m.NoiseReducer + 1) % 3);
        tgNoise.IsChecked = m.NoiseReducer != NoiseReduction.Off;
        txtNoise.Text = m.NoiseReducer switch
        {
            NoiseReduction.Low => "NOISE RED.\nbajo",
            NoiseReduction.High => "NOISE RED.\nalto",
            _ => "NOISE\nREDUCER",
        };
    }

    private void UpdateMeters()
    {
        var m = _host.Engine;
        if (!_host.Running)
        {
            // Con la consola apagada el motor no procesa audio y los medidores quedarían congelados.
            foreach (var meter in new[] { mMusic, m1, m2, mPad, mPhones, mOut }) meter.Value = -60;
            return;
        }
        mMusic.Value = m.MusicMeter.PeakDb; m1.Value = m.Mic1.Meter.PeakDb; m2.Value = m.Mic2.Meter.PeakDb;
        mPad.Value = m.PadMeter.PeakDb; mPhones.Value = m.PhonesMeter.PeakDb; mOut.Value = m.OutputMeter.PeakDb;
        for (int i = 0; i < _pads.Length; i++)
            _pads[i].Opacity = m.Pads.IsPlaying(i) ? 1.0 : 0.82;
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        _meterTimer.Stop();
        _deviceTimer.Stop();
        _watcher.Dispose();
        _host.Dispose();
    }
}
