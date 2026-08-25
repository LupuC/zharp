using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace Zharp.App.Controls;

/// <summary>
/// Invisible horizontal grip between two stacked panes. Shows a resize cursor;
/// the drag logic lives in the control hosting it, the same arrangement as
/// <see cref="SidebarSplitter"/> and for the same reason: what a drag means
/// depends on what is being resized.
/// </summary>
public sealed partial class RowSplitter : Grid
{
    public RowSplitter()
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeNorthSouth);
    }
}
