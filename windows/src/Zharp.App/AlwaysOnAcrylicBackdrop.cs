using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace Zharp.App;

/// <summary>
/// Acrylic that stays blurred while the window is inactive - the stock
/// DesktopAcrylicBackdrop falls back to a solid color on deactivation, which
/// makes acrylic look like it "doesn't work". Uses the Thin kind (the most
/// transparent) so the blur is actually visible.
/// </summary>
public sealed partial class AlwaysOnAcrylicBackdrop : SystemBackdrop
{
    private readonly bool _dark;
    private DesktopAcrylicController? _controller;

    public AlwaysOnAcrylicBackdrop(bool dark) => _dark = dark;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop connectedTarget, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(connectedTarget, xamlRoot);
        _controller = new DesktopAcrylicController { Kind = DesktopAcrylicKind.Thin };
        _controller.SetSystemBackdropConfiguration(new SystemBackdropConfiguration
        {
            IsInputActive = true,
            Theme = _dark ? SystemBackdropTheme.Dark : SystemBackdropTheme.Light,
        });
        _controller.AddSystemBackdropTarget(connectedTarget);
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop disconnectedTarget)
    {
        base.OnTargetDisconnected(disconnectedTarget);
        _controller?.RemoveSystemBackdropTarget(disconnectedTarget);
        _controller?.Dispose();
        _controller = null;
    }
}
