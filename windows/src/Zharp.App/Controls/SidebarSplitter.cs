using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace Zharp.App.Controls;

/// <summary>
/// Invisible vertical grip along the sidebar's right edge. Shows a
/// resize cursor; the drag logic lives in the window hosting it.
/// </summary>
public sealed partial class SidebarSplitter : Grid
{
    public SidebarSplitter()
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
    }
}
