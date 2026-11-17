using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace VirtualCaster.App;

/// <summary>Base de los controles de valor dibujados a mano (perilla y fader).</summary>
public abstract class ValueControl : FrameworkElement
{
    public static readonly DependencyProperty MinimumProperty = DependencyProperty.Register(
        nameof(Minimum), typeof(double), typeof(ValueControl),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty MaximumProperty = DependencyProperty.Register(
        nameof(Maximum), typeof(double), typeof(ValueControl),
        new FrameworkPropertyMetadata(1.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(ValueControl),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsRender, OnValueChanged, CoerceValue));

    public static readonly DependencyProperty DefaultValueProperty = DependencyProperty.Register(
        nameof(DefaultValue), typeof(double), typeof(ValueControl), new PropertyMetadata(0.0));

    public static readonly DependencyProperty AccentProperty = DependencyProperty.Register(
        nameof(Accent), typeof(Brush), typeof(ValueControl),
        new FrameworkPropertyMetadata(Solid(0xF5, 0xA6, 0x23), FrameworkPropertyMetadataOptions.AffectsRender));

    public double Minimum { get => (double)GetValue(MinimumProperty); set => SetValue(MinimumProperty, value); }
    public double Maximum { get => (double)GetValue(MaximumProperty); set => SetValue(MaximumProperty, value); }
    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    /// <summary>Valor al que vuelve el control con doble clic.</summary>
    public double DefaultValue { get => (double)GetValue(DefaultValueProperty); set => SetValue(DefaultValueProperty, value); }
    public Brush Accent { get => (Brush)GetValue(AccentProperty); set => SetValue(AccentProperty, value); }

    public event RoutedEventHandler? ValueChanged;

    protected ValueControl()
    {
        Focusable = false;
        Cursor = Cursors.Hand;
        IsEnabledChanged += (_, _) => InvalidateVisual();
    }

    /// <summary>Posición normalizada 0..1 del valor actual.</summary>
    protected double Position => Maximum > Minimum ? (Value - Minimum) / (Maximum - Minimum) : 0;

    private static object CoerceValue(DependencyObject d, object baseValue)
    {
        var c = (ValueControl)d;
        double v = (double)baseValue;
        if (double.IsNaN(v)) return c.Minimum;
        return Math.Max(c.Minimum, Math.Min(c.Maximum, v));
    }

    private static void OnValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((ValueControl)d).ValueChanged?.Invoke(d, new RoutedEventArgs());

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        Value += Math.Sign(e.Delta) * (Maximum - Minimum) / 40.0;
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (IsMouseCaptured) ReleaseMouseCapture();
    }

    /// <summary>Pincel sólido congelado (obligatorio para usarlo como valor por defecto de una propiedad).</summary>
    protected static SolidColorBrush Solid(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    protected static readonly Brush Transparent = Brushes.Transparent;
    protected static readonly Typeface Face = new("Segoe UI");
}

/// <summary>Perilla giratoria: arrastrar hacia arriba/abajo, rueda del ratón, doble clic para restablecer.</summary>
public sealed class Knob : ValueControl
{
    private static readonly Brush Body = new LinearGradientBrush(Color.FromRgb(0x4A, 0x4A, 0x4A), Color.FromRgb(0x18, 0x18, 0x18), 90);
    private static readonly Pen Rim = new(new SolidColorBrush(Color.FromRgb(0x62, 0x62, 0x62)), 1.2);
    private static readonly Pen TrackPen = new(new SolidColorBrush(Color.FromRgb(0x38, 0x38, 0x38)), 3) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };

    private double _dragStartY, _dragStartValue;

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { Value = DefaultValue; return; }
        _dragStartY = e.GetPosition(this).Y;
        _dragStartValue = Value;
        CaptureMouse();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!IsMouseCaptured) return;
        double dy = _dragStartY - e.GetPosition(this).Y;
        Value = _dragStartValue + dy / 160.0 * (Maximum - Minimum);
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        dc.DrawRectangle(Transparent, null, new Rect(0, 0, w, h)); // área sensible al ratón
        dc.PushOpacity(IsEnabled ? 1.0 : 0.35);

        var c = new Point(w / 2, h / 2);
        double outer = Math.Min(w, h) / 2 - 2;
        double body = outer - 6;

        // Arco de recorrido (−135° a +135°) y arco encendido hasta el valor actual.
        dc.DrawGeometry(null, TrackPen, Arc(c, outer, -135, 135));
        double angle = -135 + 270 * Position;
        if (Position > 0.001)
        {
            var lit = new Pen(Accent, 3) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
            dc.DrawGeometry(null, lit, Arc(c, outer, -135, angle));
        }

        dc.DrawEllipse(Body, Rim, c, body, body);
        var tip = Polar(c, body - 3, angle);
        var tail = Polar(c, body * 0.45, angle);
        dc.DrawLine(new Pen(Accent, Math.Max(2, body / 9)) { StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round }, tail, tip);
        dc.Pop();
    }

    private static Point Polar(Point c, double r, double degFromTop)
    {
        double a = degFromTop * Math.PI / 180;
        return new Point(c.X + r * Math.Sin(a), c.Y - r * Math.Cos(a));
    }

    private static Geometry Arc(Point c, double r, double fromDeg, double toDeg)
    {
        var g = new StreamGeometry();
        using (var ctx = g.Open())
        {
            ctx.BeginFigure(Polar(c, r, fromDeg), false, false);
            ctx.ArcTo(Polar(c, r, toDeg), new Size(r, r), 0, toDeg - fromDeg > 180, SweepDirection.Clockwise, true, false);
        }
        g.Freeze();
        return g;
    }
}

/// <summary>Fader vertical con escala 0–10.</summary>
public sealed class Fader : ValueControl
{
    private const double CapHeight = 26, Pad = 14;
    private static readonly Brush Slot = new SolidColorBrush(Color.FromRgb(0x08, 0x08, 0x08));
    private static readonly Brush Cap = new LinearGradientBrush(Color.FromRgb(0x5A, 0x5A, 0x5A), Color.FromRgb(0x22, 0x22, 0x22), 90);
    private static readonly Pen CapRim = new(new SolidColorBrush(Color.FromRgb(0x70, 0x70, 0x70)), 1);
    private static readonly Brush Tick = new SolidColorBrush(Color.FromRgb(0x9A, 0x9A, 0x9A));

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { Value = DefaultValue; return; }
        CaptureMouse();
        SetFromY(e.GetPosition(this).Y);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (IsMouseCaptured) SetFromY(e.GetPosition(this).Y);
    }

    private void SetFromY(double y)
    {
        double travel = ActualHeight - 2 * Pad;
        if (travel <= 0) return;
        double t = 1 - (y - Pad) / travel;
        Value = Minimum + Math.Max(0, Math.Min(1, t)) * (Maximum - Minimum);
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 2 * Pad) return;
        dc.DrawRectangle(Transparent, null, new Rect(0, 0, w, h));
        dc.PushOpacity(IsEnabled ? 1.0 : 0.35);

        double travel = h - 2 * Pad;
        double slotX = w * 0.62;
        dc.DrawRoundedRectangle(Slot, null, new Rect(slotX - 3, Pad - 4, 6, travel + 8), 3, 3);

        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        for (int i = 0; i <= 10; i++)
        {
            double y = Pad + travel * (1 - i / 10.0);
            dc.DrawRectangle(Tick, null, new Rect(slotX - 16, y - 0.5, i % 2 == 0 ? 9 : 5, 1));
            if (i % 2 != 0) continue;
            var text = new FormattedText(i.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, Face, 9, Tick, dpi);
            dc.DrawText(text, new Point(slotX - 20 - text.Width, y - text.Height / 2));
        }

        double capY = Pad + travel * (1 - Position);
        var capRect = new Rect(slotX - 13, capY - CapHeight / 2, 26, CapHeight);
        dc.DrawRoundedRectangle(Cap, CapRim, capRect, 4, 4);
        dc.DrawRectangle(Accent, null, new Rect(capRect.X + 3, capY - 1, capRect.Width - 6, 2));
        dc.Pop();
    }
}

/// <summary>Medidor de nivel de LED segmentados. Value en dBFS (−60 a 0).</summary>
public sealed class LedMeter : FrameworkElement
{
    private const int Segments = 12;
    private const double FloorDb = -48;

    private static readonly Brush Off = Frozen(0x2A, 0x2A, 0x2A);
    private static readonly Brush Green = Frozen(0x35, 0xE0, 0x6A);
    private static readonly Brush Amber = Frozen(0xF5, 0xC5, 0x23);
    private static readonly Brush Red = Frozen(0xFF, 0x45, 0x3A);

    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(double), typeof(LedMeter),
        new FrameworkPropertyMetadata(-60.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public double Value { get => (double)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }

    private static Brush Frozen(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 0 || h <= 0) return;
        double gap = 3, segH = (h - gap * (Segments - 1)) / Segments;
        if (segH <= 0) return;
        double db = double.IsNaN(Value) ? -60 : Value;
        for (int i = 0; i < Segments; i++)
        {
            // El segmento i (0 = inferior) se enciende al superar su umbral; el superior equivale a 0 dBFS.
            double threshold = FloorDb + (0 - FloorDb) * i / (Segments - 1);
            Brush on = i >= Segments - 2 ? Red : i >= Segments - 4 ? Amber : Green;
            double y = h - (i + 1) * segH - i * gap;
            dc.DrawRoundedRectangle(db >= threshold ? on : Off, null, new Rect(0, y, w, segH), 1.5, 1.5);
        }
    }
}
