using System.Numerics;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.UI;

namespace Zharp.App.Controls;

/// <summary>
/// Single-line text that keeps its END visible when it overflows: the text is
/// right-aligned and fades out towards the left edge, instead of
/// being tail-trimmed with an ellipsis. Drawn with Win2D because XAML has no
/// opacity masks and TextTrimming only trims trailing text.
/// </summary>
public sealed partial class TailTextBlock : Grid
{
    private const float FadeWidth = 28f;

    public static readonly DependencyProperty TextProperty =
        DependencyProperty.Register(nameof(Text), typeof(string), typeof(TailTextBlock),
            new PropertyMetadata(string.Empty, (d, _) => ((TailTextBlock)d)._canvas.Invalidate()));

    public static readonly DependencyProperty FontSizeProperty =
        DependencyProperty.Register(nameof(FontSize), typeof(double), typeof(TailTextBlock),
            new PropertyMetadata(12.0, (d, _) =>
            {
                var self = (TailTextBlock)d;
                self.UpdateMetrics();
                self._canvas.Invalidate();
            }));

    /// <summary>On overflow: true keeps the TAIL visible (paths), false keeps
    /// the HEAD visible and fades the right edge out (commands).</summary>
    public static readonly DependencyProperty TailFirstProperty =
        DependencyProperty.Register(nameof(TailFirst), typeof(bool), typeof(TailTextBlock),
            new PropertyMetadata(true, (d, _) => ((TailTextBlock)d)._canvas.Invalidate()));

    public bool TailFirst
    {
        get => (bool)GetValue(TailFirstProperty);
        set => SetValue(TailFirstProperty, value);
    }

    /// <summary>Explicit text color; transparent (default) = theme color.</summary>
    public static readonly DependencyProperty TintProperty =
        DependencyProperty.Register(nameof(Tint), typeof(Color), typeof(TailTextBlock),
            new PropertyMetadata(Microsoft.UI.Colors.Transparent,
                (d, _) => ((TailTextBlock)d)._canvas.Invalidate()));

    public Color Tint
    {
        get => (Color)GetValue(TintProperty);
        set => SetValue(TintProperty, value);
    }

    private readonly CanvasControl _canvas = new() { ClearColor = Microsoft.UI.Colors.Transparent };
    private CanvasTextFormat? _format;
    private bool _bold;

    public TailTextBlock()
    {
        Children.Add(_canvas);
        _canvas.Draw += OnDraw;
        SizeChanged += (_, _) => _canvas.Invalidate();
        ActualThemeChanged += (_, _) => _canvas.Invalidate();
        UpdateMetrics();
    }

    public string Text
    {
        get => (string)GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    public double FontSize
    {
        get => (double)GetValue(FontSizeProperty);
        set => SetValue(FontSizeProperty, value);
    }

    /// <summary>
    /// SemiBold when true. A dependency property rather than a plain one so a
    /// card can bind it to per-item state: a session's status line goes bold
    /// while its agent is blocked, and back when it is not.
    /// </summary>
    public static readonly DependencyProperty EmphasisBoldProperty =
        DependencyProperty.Register(nameof(EmphasisBold), typeof(bool), typeof(TailTextBlock),
            new PropertyMetadata(false, (d, e) =>
            {
                var self = (TailTextBlock)d;
                self._bold = (bool)e.NewValue;
                self.UpdateMetrics();
                self._canvas.Invalidate();
            }));

    public bool EmphasisBold
    {
        get => (bool)GetValue(EmphasisBoldProperty);
        set => SetValue(EmphasisBoldProperty, value);
    }

    /// <summary>Right-align the text when it fits (it already right-aligns on
    /// overflow). For fixed-width slots that hug the right edge.</summary>
    public bool AlignTrailing
    {
        get => _alignTrailing;
        set
        {
            _alignTrailing = value;
            _canvas.Invalidate();
        }
    }

    private bool _alignTrailing;

    private void UpdateMetrics()
    {
        _format = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Variable Text",
            FontSize = (float)FontSize,
            FontWeight = _bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
            WordWrapping = CanvasWordWrapping.NoWrap,
            HorizontalAlignment = CanvasHorizontalAlignment.Left,
            VerticalAlignment = CanvasVerticalAlignment.Top,
        };
        try
        {
            using var probe = new CanvasTextLayout(CanvasDevice.GetSharedDevice(), "Ag", _format, 0, 0);
            MinHeight = Math.Ceiling(probe.LayoutBounds.Height);
        }
        catch
        {
            MinHeight = Math.Ceiling(FontSize * 1.5);
        }
    }

    private void OnDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        string text = Text;
        if (string.IsNullOrEmpty(text) || _format == null || sender.ActualWidth <= 1)
            return;

        Color color = Tint.A != 0
            ? Tint
            : ActualTheme == ElementTheme.Dark
                ? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF)
                : Color.FromArgb(0xFF, 0x1B, 0x1D, 0x21);

        using var layout = new CanvasTextLayout(sender, text, _format, 0, 0);
        float textWidth = (float)layout.LayoutBounds.Width;
        float width = (float)sender.ActualWidth;
        float y = (float)Math.Max(0, (sender.ActualHeight - layout.LayoutBounds.Height) / 2);

        if (textWidth <= width)
        {
            float fitX = _alignTrailing ? width - textWidth : 0;
            args.DrawingSession.DrawTextLayout(layout, fitX, y, color);
            return;
        }

        if (TailFirst)
        {
            // Overflow: right-align so the tail stays visible, fade the left edge in.
            float x = width - textWidth;
            var stops = new CanvasGradientStop[]
            {
                new() { Position = 0f, Color = Color.FromArgb(0x00, color.R, color.G, color.B) },
                new() { Position = 1f, Color = color },
            };
            using var brush = new CanvasLinearGradientBrush(sender, stops)
            {
                StartPoint = new Vector2(0, 0),
                EndPoint = new Vector2(FadeWidth, 0),
            };
            args.DrawingSession.DrawTextLayout(layout, x, y, brush);
        }
        else
        {
            // Overflow: keep the head (commands read left to right), fade out
            // at the right edge.
            var stops = new CanvasGradientStop[]
            {
                new() { Position = 0f, Color = color },
                new() { Position = 1f, Color = Color.FromArgb(0x00, color.R, color.G, color.B) },
            };
            using var brush = new CanvasLinearGradientBrush(sender, stops)
            {
                StartPoint = new Vector2(width - FadeWidth, 0),
                EndPoint = new Vector2(width, 0),
            };
            args.DrawingSession.DrawTextLayout(layout, 0, y, brush);
        }
    }
}
