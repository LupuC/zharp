using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Zharp.App.Controls;

namespace Zharp.App;

/// <summary>
/// Crisp whole-chrome zoom: multiplies the REAL font sizes and control
/// dimensions instead of using scale transforms (XAML does not re-rasterize
/// under transforms, which makes transform-zoomed chrome pixelated).
/// Each element's base value is captured on first touch via attached
/// properties, so any zoom factor is applied idempotently from the original.
/// </summary>
public static class ChromeZoom
{
    private static readonly DependencyProperty BaseFontProperty =
        DependencyProperty.RegisterAttached("BaseFont", typeof(double), typeof(ChromeZoom),
            new PropertyMetadata(double.NaN));

    private static readonly DependencyProperty BaseWidthProperty =
        DependencyProperty.RegisterAttached("BaseWidth", typeof(double), typeof(ChromeZoom),
            new PropertyMetadata(double.NaN));

    private static readonly DependencyProperty BaseHeightProperty =
        DependencyProperty.RegisterAttached("BaseHeight", typeof(double), typeof(ChromeZoom),
            new PropertyMetadata(double.NaN));

    private static readonly DependencyProperty BaseMinHeightProperty =
        DependencyProperty.RegisterAttached("BaseMinHeight", typeof(double), typeof(ChromeZoom),
            new PropertyMetadata(double.NaN));

    public static void Apply(UIElement root, double zoom) => Walk(root, zoom);

    private static void Walk(DependencyObject node, double zoom)
    {
        // The terminal zooms via its own font pipeline.
        if (node is TerminalView)
            return;

        // Session cards/pills scale through SessionItem's bound sizes - the
        // walker must not fight those bindings.
        if (node is FrameworkElement fe && (fe.Name == "SessionList" || fe.Name == "SessionStrip"))
            return;

        switch (node)
        {
            case TailTextBlock tail:
                Scale(tail, TailTextBlock.FontSizeProperty, BaseFontProperty, zoom);
                return; // draws itself; nothing inside to walk
            case TextBlock text:
                Scale(text, TextBlock.FontSizeProperty, BaseFontProperty, zoom);
                break;
            case FontIcon icon:
                Scale(icon, FontIcon.FontSizeProperty, BaseFontProperty, zoom);
                break;
            case Image image:
                ScaleSize(image, zoom);
                break;
            // Controls only scale fonts they set LOCALLY - inner template parts
            // (e.g. the TextBox inside an AutoSuggestBox) inherit the scaled
            // value and must not be multiplied a second time.
            case Button button:
                ScaleLocalFont(button, zoom);
                ScaleSize(button, zoom);
                break;
            case AutoSuggestBox suggest:
                ScaleLocalFont(suggest, zoom);
                // The inner TextBox's MinHeight comes from a theme resource and
                // won't grow with the font - scale it directly. Also center its
                // content vertically: the stock template top-aligns text when the
                // box is taller than text+padding.
                if (FindDescendant<TextBox>(suggest) is { } inner)
                {
                    inner.VerticalContentAlignment = VerticalAlignment.Center;
                    Scale(inner, FrameworkElement.MinHeightProperty, BaseMinHeightProperty, zoom);
                }
                break;
            case ComboBox combo:
                ScaleLocalFont(combo, zoom);
                ScaleSize(combo, zoom);
                break;
            case NumberBox number:
                ScaleLocalFont(number, zoom);
                ScaleSize(number, zoom);
                if (FindDescendant<TextBox>(number) is { } numberInner)
                    numberInner.VerticalContentAlignment = VerticalAlignment.Center;
                break;
            case Control control:
                ScaleLocalFont(control, zoom);
                break;
        }

        int count = VisualTreeHelper.GetChildrenCount(node);
        for (int i = 0; i < count; i++)
            Walk(VisualTreeHelper.GetChild(node, i), zoom);
    }

    private static void ScaleLocalFont(Control control, double zoom)
    {
        // Once we've captured a base, keep scaling (our own SetValue made it "local").
        if (double.IsNaN((double)control.GetValue(BaseFontProperty)) &&
            control.ReadLocalValue(Control.FontSizeProperty) == DependencyProperty.UnsetValue)
        {
            return;
        }
        Scale(control, Control.FontSizeProperty, BaseFontProperty, zoom);
    }

    private static void Scale(DependencyObject d, DependencyProperty target,
        DependencyProperty baseStore, double zoom)
    {
        double baseValue = (double)d.GetValue(baseStore);
        if (double.IsNaN(baseValue))
        {
            baseValue = (double)d.GetValue(target);
            if (double.IsNaN(baseValue) || baseValue <= 0)
                return;
            d.SetValue(baseStore, baseValue);
        }
        d.SetValue(target, baseValue * zoom);
    }

    private static void ScaleSize(FrameworkElement element, double zoom)
    {
        double baseW = (double)element.GetValue(BaseWidthProperty);
        if (double.IsNaN(baseW) && !double.IsNaN(element.Width))
            element.SetValue(BaseWidthProperty, baseW = element.Width);
        if (!double.IsNaN(baseW))
            element.Width = baseW * zoom;

        double baseH = (double)element.GetValue(BaseHeightProperty);
        if (double.IsNaN(baseH) && !double.IsNaN(element.Height))
            element.SetValue(BaseHeightProperty, baseH = element.Height);
        if (!double.IsNaN(baseH))
            element.Height = baseH * zoom;
    }

    private static T? FindDescendant<T>(DependencyObject node) where T : DependencyObject
    {
        int count = VisualTreeHelper.GetChildrenCount(node);
        for (int i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(node, i);
            if (child is T match)
                return match;
            if (FindDescendant<T>(child) is { } deeper)
                return deeper;
        }
        return null;
    }
}
